{
  description = "NixOS deployment flake for bookmarks (uv2nix venv + hardened systemd unit + Caddy + agenix + daily backup).";

  # NOTE: this is the *deployment* flake and intentionally lives at nixos/, NOT
  # the repo root. The repo-root flake.nix is the Playwright e2e-harness
  # devshell (todo 13); the two flakes are independent and must not collide.

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # uv2nix hello-world template (pyproject-nix/uv2nix#hello-world).
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The repository root (pyproject.toml + uv.lock + app/). A flake cannot
    # read outside its own source tree, so the uv workspace is loaded from this
    # explicit path input instead of a `../` path literal. The bare relative
    # path resolves against this flake's directory (Nix >= 2.26) and is
    # portable: on a checkout anywhere, `../` is that checkout's root.
    repo = {
      url = "../";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      pyproject-nix,
      uv2nix,
      pyproject-build-systems,
      agenix,
      repo,
    }:
    let
      inherit (nixpkgs) lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = lib.genAttrs systems;

      # --- uv2nix hello-world pattern ---------------------------------------
      # Normalize the `../` input to a clean store path: Nix's relative-path
      # resolution leaves the value as "<flake-store>/nixos/..", which works for
      # reading but breaks a derivation's unpackPhase (cp -r "<...>/nixos/.." .
      # resolves the trailing ".." against the build dir). builtins.path rewrites
      # it as a plain "/nix/store/<hash>-bookmarks-repo" source tree.
      repoRoot = builtins.path { path = repo; name = "bookmarks-repo"; };

      workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = repoRoot; };

      overlay = workspace.mkPyprojectOverlay {
        sourcePreference = "wheel";
      };

      # Build fixups that uv.lock cannot express. Kept empty for now: with
      # sourcePreference = "wheel" every dependency is installed from a binary
      # wheel and pyproject-build-systems.overlays.wheel supplies the build
      # backends, so nothing else is needed on this dependency set.
      pyprojectOverrides = final: prev: { };

      pythonSets = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          python = pkgs.python312;
        in
        (pkgs.callPackage pyproject-nix.build.packages { inherit python; }).overrideScope (
          lib.composeManyExtensions [
            pyproject-build-systems.overlays.wheel
            overlay
            pyprojectOverrides
          ]
        )
      );

      # Virtualenv built from uv.lock with only the runtime dependencies.
      venvFor = system: pythonSets.${system}.mkVirtualEnv "bookmarks-env" workspace.deps.default;

      # How scripts/backup.sh reaches the Nix store: a pkgs.writeShellScript
      # derivation. When the repo ships scripts/backup.sh (todo 37) its exact
      # contents are copied into the store via lib.strings.fileContents; until
      # then a built-in equivalent (online sqlite3 .backup + integrity check +
      # prune) keeps the systemd timer path resolving. Either way the timer
      # points at a Nix-store path, never a mutable source file.
      backupScriptFor = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          repoBackup = "${repoRoot}/scripts/backup.sh";
        in
        if builtins.pathExists repoBackup then
          pkgs.writeShellScript "bookmarks-backup.sh" (lib.strings.fileContents repoBackup)
        else
          pkgs.writeShellScript "bookmarks-backup.sh" ''
            # Fallback until scripts/backup.sh ships (todo 37): online SQLite
            # backup via the sqlite3 .backup API (safe while the app holds the
            # DB open), integrity check, then prune copies older than
            # BACKUP_KEEP_DAYS. Automatically replaced by the repo script once
            # it exists.
            set -eu
            db="''${BOOKMARKS_DB:-}"
            backup_dir="''${BACKUP_DIR:-/var/lib/private/bookmarks/backups}"
            retain="''${BACKUP_KEEP_DAYS:-14}"
            if [ -z "$db" ] || [ ! -r "$db" ]; then
              echo "bookmarks-backup: BOOKMARKS_DB not set or not readable: $db" >&2
              exit 1
            fi
            mkdir -p "$backup_dir"
            stamp="$(date +%F-%T)"
            dest="$backup_dir/bookmarks-$stamp.db"
            if ! "${pkgs.sqlite}/bin/sqlite3" "$db" ".backup '$dest'"; then
              echo "bookmarks-backup: sqlite3 .backup failed" >&2
              rm -f "$dest"
              exit 1
            fi
            if [ "$("${pkgs.sqlite}/bin/sqlite3" "$dest" "PRAGMA integrity_check;")" != "ok" ]; then
              echo "bookmarks-backup: integrity check failed on $dest" >&2
              rm -f "$dest"
              exit 1
            fi
            "${pkgs.findutils}/bin/find" "$backup_dir" -name 'bookmarks-*.db' -mtime "+$retain" -delete
            echo "bookmarks-backup: wrote $dest"
          '';
    in
    {
      packages = forAllSystems (system: {
        default = (venvFor system).overrideAttrs (old: {
          # Lets `nix run .#bookmarks-server` resolve when invoked via packages.
          meta = (old.meta or { }) // { mainProgram = "bookmarks-server"; };
        });
      });

      apps = forAllSystems (system: {
        bookmarks-server = {
          type = "app";
          program = "${venvFor system}/bin/bookmarks-server";
        };
      });

      nixosModules.default = { lib, config, pkgs, ... }:
        let
          cfg = config.services.bookmarks;
          package =
            self.packages.${pkgs.system}.default
            or (throw "bookmarks: unsupported NixOS system ${pkgs.system}");
          backupScript = backupScriptFor pkgs.system;
          stateDir = "/var/lib/private/bookmarks";
          # agenix secret is optional so a fresh checkout (and this flake's CI
          # gates) evaluate without committing any secret material. The runbook
          # explains how to provision nixos/secrets/bookmarks-env.age.
          hasSecretFile = builtins.pathExists ./secrets/bookmarks-env.age;
        in
        {
          imports = [ agenix.nixosModules.age ];

          options.services.bookmarks = {
            enable = lib.mkEnableOption "the bookmarks knowledge-base web service";

            domain = lib.mkOption {
              type = lib.types.str;
              description = "Public hostname. Caddy serves it with automatic HTTPS (ACME) and reverse-proxies to 127.0.0.1:{port}. Also used as PUBLIC_ORIGIN and WEBAUTHN_RP_ID.";
            };

            port = lib.mkOption {
              type = lib.types.port;
              default = 8000;
              description = "Loopback port uvicorn binds to (Caddy reverse_proxy target).";
            };

            extraEnv = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
              description = "Additional non-secret environment variables for the service (e.g. EXPORT_TOOLBAR_TAG).";
            };

            backup = {
              enable = lib.mkEnableOption "the daily bookmarks database backup timer";
              schedule = lib.mkOption {
                type = lib.types.str;
                default = "*-*-* 03:17:00";
                description = "systemd OnCalendar expression for the backup timer.";
              };
              retainDays = lib.mkOption {
                type = lib.types.int;
                default = 14;
                description = "Backups older than this many days are pruned.";
              };
              offboxDest = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Optional BACKUP_OFFBOX_DEST (S3-compatible URL) passed to the backup script for an offsite copy.";
              };
            };
          };

          config = lib.mkIf cfg.enable {
            # agenix-managed env file holding SECRET_KEY plus optional API keys
            # (OPENAI_API_KEY, ANTHROPIC_API_KEY, ...). Provision with:
            #   nix run .#agenix -e nixos/secrets/bookmarks-env.age
            age.secrets.bookmarks-env = lib.mkIf hasSecretFile {
              file = ./secrets/bookmarks-env.age;
              owner = "root";
              group = "root";
              mode = "0400";
            };

            services.caddy = {
              enable = true;
              virtualHosts.${cfg.domain} = {
                # Automatic HTTPS: Caddy obtains and renews an ACME certificate
                # for cfg.domain and proxies to the loopback uvicorn socket.
                extraConfig = ''
                  encode zstd gzip
                  reverse_proxy 127.0.0.1:${toString cfg.port}
                '';
              };
            };

            systemd.services.bookmarks = {
              description = "bookmarks knowledge-base web service";
              wantedBy = [ "multi-user.target" ];
              after = [ "network.target" ];

              serviceConfig = {
                Type = "simple";
                # Ephemeral user; StateDirectory=bookmarks maps to
                # /var/lib/private/bookmarks (systemd-managed, survives restarts).
                DynamicUser = true;
                StateDirectory = "bookmarks";

                Environment =
                  [
                    "BOOKMARKS_DB=${stateDir}/bookmarks.db"
                    "PUBLIC_ORIGIN=https://${cfg.domain}"
                    "WEBAUTHN_RP_ID=${cfg.domain}"
                  ]
                  ++ (lib.mapAttrsToList (k: v: "${k}=${v}") cfg.extraEnv);

                # The agenix-decrypted env file is injected as a systemd
                # credential: systemd reads it as root (DynamicUser-proof) and
                # re-exports it at $CREDENTIALS_DIRECTORY/bookmarks-env.
                LoadCredential = lib.mkIf hasSecretFile [
                  "bookmarks-env:${config.age.secrets.bookmarks-env.path}"
                ];

                # Hardening. The memory deny-write-execute policy is
                # deliberately NOT enabled: it breaks the V8/Node JIT
                # (Chromium snapshotting) and a test runner's require() if an
                # e2e runner is ever added to this unit.
                CapabilityBoundingSet = [ "" ];
                NoNewPrivileges = true;
                ProtectSystem = "strict";
                ProtectHome = true;
                PrivateTmp = true;
                PrivateDevices = true;
                ProtectKernelTunables = true;
                ProtectKernelModules = true;
                ProtectKernelLogs = true;
                ProtectControlGroups = true;
                ProtectClock = true;
                RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
                RestrictRealtime = true;
                RestrictSUIDSGID = true;
                LockPersonality = true;
                RemoveIPC = true;
                UMask = "0027";
                Restart = "on-failure";
                RestartSec = "5s";
              };

              script = ''
                # Export the agenix-provided credential (SECRET_KEY, API keys)
                # into the process environment if one was provisioned.
                if [ -f "$CREDENTIALS_DIRECTORY/bookmarks-env" ]; then
                  set -a
                  . "$CREDENTIALS_DIRECTORY/bookmarks-env"
                  set +a
                fi
                exec ${package}/bin/uvicorn app.main:app --host 127.0.0.1 --port ${toString cfg.port}
              '';
            };

            # Backup timer. Runs scripts/backup.sh (or the built-in equivalent)
            # as a hardened, network-isolated root oneshot: the app's state dir
            # lives behind the root-owned 0700 /var/lib/private boundary, which
            # systemd only relaxes inside the owning DynamicUser's mount
            # namespace, so no second unit can reach the DB as the app's user.
            # A minimal capability bounding set (read + traverse the boundary,
            # unlink stale backups) and an AF_UNIX-only address family keep the
            # blast radius small; the script itself is a Nix-store derivation.
            systemd.services.bookmarks-backup = lib.mkIf cfg.backup.enable {
              description = "Daily online SQLite backup of the bookmarks database";
              after = [ "bookmarks.service" ];
              serviceConfig = {
                Type = "oneshot";
                CapabilityBoundingSet = [
                  "CAP_DAC_OVERRIDE"
                  "CAP_DAC_READ_SEARCH"
                  "CAP_FOWNER"
                ];
                NoNewPrivileges = true;
                ProtectSystem = "strict";
                ProtectHome = true;
                PrivateTmp = true;
                PrivateDevices = true;
                ProtectKernelTunables = true;
                ProtectKernelModules = true;
                ProtectControlGroups = true;
                RestrictAddressFamilies = [ "AF_UNIX" ];
                RestrictRealtime = true;
                UMask = "0027";
                Environment =
                  [
                    "BOOKMARKS_DB=${stateDir}/bookmarks.db"
                    "BACKUP_DIR=${stateDir}/backups"
                    "BACKUP_KEEP_DAYS=${toString cfg.backup.retainDays}"
                  ]
                  ++ (lib.optional (cfg.backup.offboxDest != null) "BACKUP_OFFBOX_DEST=${cfg.backup.offboxDest}");
                # scripts/backup.sh expects sqlite3/find/coreutils on PATH; the
                # unit's PATH is otherwise minimal on NixOS.
                path = [
                  pkgs.sqlite
                  pkgs.findutils
                  pkgs.coreutils
                  pkgs.gnused
                ];
                ExecStart = "${backupScript}/bin/bookmarks-backup.sh";
              };
            };

            systemd.timers.bookmarks-backup = lib.mkIf cfg.backup.enable {
              description = "Daily bookmarks backup timer";
              wantedBy = [ "timers.target" ];
              timerConfig = {
                OnCalendar = cfg.backup.schedule;
                Persistent = true;
                RandomizedDelaySec = "30m";
              };
            };
          };
        };
    };
}
