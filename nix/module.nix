# eza NixOS module.
#
# The pinned package defaults (ezaPackage / ezaWebAssets / secretspecManifest)
# are supplied by the flake through `_module.args` (see nixosModules.default in
# flake.nix), so this file stays a normal NixOS module. Import it through the
# flake:
#
#   {
#     inputs.eza.url = "github:meillaya/eza";
#     inputs.eza.inputs.nixpkgs.follows = "nixpkgs";
#
#     # configuration.nix
#     imports = [ inputs.eza.nixosModules.default ];
#     services.eza = {
#       enable = true;
#       publicOrigin = "https://eza.example.com";
#       rpId = "eza.example.com";
#       caddy.enable = true;
#       caddy.hostname = "eza.example.com";
#     };
#   }
#
# The deployed binary is `eza-bookmarks` (server + CLI). See
# docs/deployment-nixos.md for the operator runbook and docs/secrets.md for
# SecretSpec / systemd-credential provisioning.
{
  config,
  lib,
  pkgs,
  ezaPackage,
  ezaWebAssets,
  secretspecManifest,
  ...
}:

let
  cfg = config.services.eza;

  inherit (lib)
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    optional
    optionalAttrs
    optionalString
    types
    ;

  # ---------------------------------------------------------------------------
  # Derived values
  # ---------------------------------------------------------------------------
  dataDir = lib.removeSuffix "/" cfg.dataDir;

  # systemd's StateDirectory= only manages single path components below
  # /var/lib. The default dataDir is /var/lib/eza, which maps to
  # StateDirectory=eza; anything else is created with tmpfiles and granted
  # access through ReadWritePaths.
  stateDirName = lib.removePrefix "/var/lib/" dataDir;
  stateDirSupported =
    lib.hasPrefix "/var/lib/" dataDir && stateDirName != "" && !(lib.hasInfix "/" stateDirName);

  stateDirConfig = optionalAttrs stateDirSupported {
    StateDirectory = stateDirName;
    StateDirectoryMode = "0750";
  };
  extraReadWritePaths = optional (!stateDirSupported) dataDir;

  # EZA_BIND is "host:port". Parse it once so the Caddy/Tailscale proxies and
  # the health probe target agree with the server.
  bindMatch = builtins.match "(.+):([0-9]+)" cfg.bind;
  bindHost = if bindMatch == null then "127.0.0.1" else builtins.elemAt bindMatch 0;
  bindPort = if bindMatch == null then 8080 else lib.toInt (builtins.elemAt bindMatch 1);
  # Environment representation for booleans: the server accepts 1/0 and
  # true/false; 1/0 is what the systemd unit and the container images use.
  boolToEnv = b: if b then "1" else "0";

  # Host part of an origin (scheme://host[:port][/path]) for the default RP ID.
  originHost =
    origin:
    let
      afterScheme = lib.last (lib.splitString "://" origin);
      authority = lib.head (lib.splitString "/" afterScheme);
    in
    lib.toLower (lib.removeSuffix "." (lib.head (lib.splitString ":" authority)));

  defaultPublicOrigin =
    if cfg.caddy.enable && cfg.caddy.hostname != null then
      "https://${cfg.caddy.hostname}"
    else
      "http://localhost:${toString bindPort}";

  # Where the browser bundle lives. Either the operator-supplied staticDir or
  # the webAssets package (share/eza/static: index.html, app/app.wasm, ...).
  staticDirPath = if cfg.staticDir != null then cfg.staticDir else "${cfg.webAssets}/share/eza/static";

  # ExecStart is wrapped in SecretSpec. systemd only exports
  # CREDENTIALS_DIRECTORY for units that have credentials configured, while
  # SecretSpec's systemd-credential provider requires it. When no credential
  # files are configured we point the provider at a private empty directory:
  # every secret in the manifest is optional, so an empty provider resolves to
  # "unset" and the optional AI features simply stay disabled.
  secretspecRun = pkgs.writeShellScript "eza-secretspec-run" ''
    set -eu

    if [ -z "''${CREDENTIALS_DIRECTORY:-}" ]; then
      CREDENTIALS_DIRECTORY=${lib.escapeShellArg "${dataDir}/.credentials"}
      export CREDENTIALS_DIRECTORY
      mkdir -p "$CREDENTIALS_DIRECTORY"
      chmod 0700 "$CREDENTIALS_DIRECTORY"
    fi

    exec ${pkgs.secretspec}/bin/secretspec run --file ${cfg.secretspecFile} --provider ${lib.escapeShellArg cfg.secretspecProvider} --profile production -- ${lib.escapeShellArg "${cfg.package}/bin/eza-bookmarks"} serve
  '';

  # Startup readiness probe: don't report the unit "active" before Warp answers
  # /healthz. Non-fatal (prefix "-") so a slow first migration cannot wedge the
  # restart loop; the unit stays up and the probe result is logged.
  healthzWait = pkgs.writeShellScript "eza-healthz-wait" ''
    for _ in $(seq 1 60); do
      if ${cfg.package}/bin/eza-bookmarks healthcheck > /dev/null 2>&1; then
        exit 0
      fi
      sleep 0.5
    done
    echo "eza: /healthz did not answer within 30s; continuing (see journal)" >&2
    exit 0
  '';

  # Hardening shared by the main service and the backup oneshot.
  commonHardening = {
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
    ProtectHostname = true;
    ProtectProc = "invisible";
    ProcSubset = "pid";
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
    ];
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    RemoveIPC = true;
    SystemCallArchitectures = "native";
  };
in
{
  # ---------------------------------------------------------------------------
  # Options
  # ---------------------------------------------------------------------------
  options.services.eza = {
    enable = mkEnableOption "the eza bookmark manager";

    package = mkOption {
      type = types.package;
      default = ezaPackage;
      defaultText = lib.literalExpression "the eza-bookmarks package from the eza flake";
      description = ''
        The eza server package. It provides `bin/eza-bookmarks` (the release
        binary is named eza-bookmarks; `serve` starts the web server).
      '';
    };

    webAssets = mkOption {
      type = types.package;
      default = ezaWebAssets;
      defaultText = lib.literalExpression "the eza-web package from the eza flake (CI-built release asset)";
      description = ''
        Package containing the browser bundle at `share/eza/static`
        (index.html, eza.css, app/app.wasm, ...). The default is the
        CI-built, fixed-output release asset pinned by the flake. For a local
        checkout, point this at `packages.<system>.eza-web-local`.
      '';
    };

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/eza";
      description = ''
        Directory holding `control.db`, the `users/<id>/eza.db` library files
        and the `snapshots/` and `backups/` subdirectories (EZA_DATA_DIR). The
        default is managed by systemd as StateDirectory=eza and owned by the
        fixed `eza` non-root user. A path outside /var/lib is created with
        tmpfiles and granted via ReadWritePaths instead.
      '';
    };

    bind = mkOption {
      type = types.str;
      default = "127.0.0.1:8080";
      example = "0.0.0.0:8080";
      description = ''
        Address and port the Warp server listens on (EZA_BIND). Keep it on
        loopback when Caddy or Tailscale Serve is the public frontend.
      '';
    };

    publicOrigin = mkOption {
      type = types.str;
      default = defaultPublicOrigin;
      defaultText = lib.literalExpression ''
        "https://<caddy.hostname>" when Caddy is enabled,
        otherwise "http://localhost:<bind port>"
      '';
      example = "https://eza.example.com";
      description = ''
        Browser-visible origin (PUBLIC_ORIGIN), e.g. `https://eza.example.com`.
        WebAuthn passkeys are bound to this origin, so it must be exactly what
        users type in the address bar. It also drives the default rpId and
        whether cookies are Secure (https origins get Secure cookies).
      '';
    };

    rpId = mkOption {
      type = types.str;
      default = originHost cfg.publicOrigin;
      defaultText = lib.literalExpression "the host part of services.eza.publicOrigin";
      example = "eza.example.com";
      description = ''
        WebAuthn relying-party ID (EZA_RP_ID): the publicOrigin's host name,
        without scheme or port. Do not change it after registering passkeys:
        existing credentials are bound to the old RP ID.
      '';
    };

    rpName = mkOption {
      type = types.str;
      default = "eza";
      description = "Human-readable relying-party name shown by passkey prompts (EZA_RP_NAME).";
    };

    logLevel = mkOption {
      type = types.str;
      default = "info";
      description = "Server log level (EZA_LOG_LEVEL: debug, info, warn, error).";
    };
    allowPrivateFetch = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Allow the enrichment fetcher to request private/RFC1918 addresses
        (EZA_ALLOW_PRIVATE_FETCH). Off by default: the server refuses to fetch
        loopback, link-local and private-network URLs, so the server-side
        fetcher cannot be used as an SSRF probe through the web UI.
      '';
    };

    enrichWorkers = mkOption {
      type = types.int;
      default = 2;
      description = ''
        Number of in-process background enrichment workers
        (EZA_ENRICH_WORKERS). Workers fetch titles, favicons and extracted
        text for queued bookmarks; each opens its own SQLite connection inside
        the server process, so no extra systemd unit is involved. 0 disables
        the background workers (adding bookmarks still works; they stay
        unenriched until re-queued).
      '';
    };

    fetchTimeoutMs = mkOption {
      type = types.int;
      default = 8000;
      example = 15000;
      description = ''
        Timeout for each outbound enrichment/fetch request in milliseconds
        (EZA_FETCH_TIMEOUT_MS). The server clamps values below 1000.
      '';
    };

    faviconMaxBytes = mkOption {
      type = types.int;
      default = 262144;
      description = ''
        Maximum favicon download size in bytes (EZA_FAVICON_MAX_BYTES); larger
        responses are discarded. Complete ICO entries are cropped before
        storage. The server clamps values below 4096.
      '';
    };

    faviconTtlDays = mkOption {
      type = types.int;
      default = 90;
      description = ''
        Favicon cache lifetime in days (EZA_FAVICON_TTL_DAYS); exhausted
        missing-domain work is followed by one expired-icon refresh per
        backfill tick.
      '';
    };

    shareTtlDays = mkOption {
      type = types.int;
      default = 7;
      description = ''
        Lifetime of public share links in days (EZA_SHARE_TTL_DAYS); links
        stop resolving after this many days.
      '';
    };

    aiProvider = mkOption {
      type = types.enum [
        "none"
        "ollama"
        "openai"
        "openai-compatible"
        "anthropic"
      ];
      default = "none";
      description = ''
        AI tagging provider (EZA_AI_PROVIDER). "none" disables AI tagging; the
        AI endpoints then return an empty suggestion list with a notice.
        "ollama" uses a local Ollama at `ollamaBaseUrl` and needs no API key;
        "openai" and "openai-compatible" use OPENAI_API_KEY; "anthropic" uses
        ANTHROPIC_API_KEY.
      '';
    };

    ollamaBaseUrl = mkOption {
      type = types.str;
      default = "http://127.0.0.1:11434";
      description = "Ollama base URL for AI tagging (EZA_OLLAMA_BASE_URL) when aiProvider is \"ollama\".";
    };

    aiModel = mkOption {
      type = types.str;
      default = "";
      description = ''
        Model name used for AI tagging (EZA_AI_MODEL). Empty selects the
        provider default: `llama3.2` for Ollama, `gpt-4o-mini` for OpenAI,
        `claude-haiku-4-5` for Anthropic. AI suggestions are always requested
        explicitly from the UI.
      '';
    };

    environmentFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/eza.env";
      description = ''
        Optional systemd EnvironmentFile (absolute path *string*, e.g.
        `/run/secrets/eza.env`) with extra non-secret settings. Prefer the
        dedicated API-key options for secrets; values from this file are also
        visible to SecretSpec's `env` provider fallback.
      '';
    };

    staticDir = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/srv/eza/static";
      description = ''
        Optional override for EZA_STATIC_DIR. By default the module serves the
        bundle from `services.eza.webAssets` (`share/eza/static`).
      '';
    };

    secretspecFile = mkOption {
      type = types.path;
      default = secretspecManifest;
      defaultText = lib.literalExpression "the secretspec.toml shipped with the eza flake";
      description = ''
        SecretSpec manifest used to resolve optional AI API keys. The manifest
        declares secrets, never values; it is safe to keep in the Nix store.
      '';
    };

    secretspecProvider = mkOption {
      type = types.str;
      default = "systemd-credential";
      description = ''
        SecretSpec provider used by the wrapped ExecStart. The default reads
        systemd credentials (see `anthropicApiKeyFile` / `openaiApiKeyFile`);
        set to `"env"` to resolve the same optional secrets from environment
        variables instead.
      '';
    };

    anthropicApiKeyFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/agenix/eza-anthropic-api-key";
      description = ''
        Optional absolute path to a file containing the Anthropic API key. It
        is loaded as the `ANTHROPIC_API_KEY` systemd credential and resolved
        by SecretSpec's systemd-credential provider. Write the key *without a
        trailing newline* (e.g. `printf %s "$KEY" > file`). The file is read
        by root at unit start; point it at an agenix/sops-nix secret path.
      '';
    };

    openaiApiKeyFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/agenix/eza-openai-api-key";
      description = ''
        Optional absolute path to a file containing the OpenAI (or
        OpenAI-compatible) API key, loaded as the `OPENAI_API_KEY` systemd
        credential. Same rules as `anthropicApiKeyFile`.
      '';
    };

    tailscaleServe = {
      enable = mkEnableOption "publishing eza via Tailscale Serve HTTPS (recommended; passkeys require a secure origin)";

      httpsPort = mkOption {
        type = types.port;
        default = 443;
        description = ''
          Tailscale Serve HTTPS port. Tailscale only accepts 443 (the tailnet
          root), 8443, or 10000; use 8443 or 10000 if the tailnet root is taken.
        '';
      };
    };

    caddy = {
      enable = mkEnableOption "a Caddy reverse proxy with automatic HTTPS in front of eza";

      hostname = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "eza.example.com";
        description = ''
          Public hostname Caddy serves with automatic ACME HTTPS and proxies to
          services.eza.bind. When set (and publicOrigin is left at its
          default), it also becomes publicOrigin and rpId.
        '';
      };
    };

    backup = {
      enable = mkEnableOption "a daily online SQLite backup timer";

      schedule = mkOption {
        type = types.str;
        default = "*-*-* 03:17:00";
        description = "systemd OnCalendar expression for the backup timer.";
      };

      keepDays = mkOption {
        type = types.int;
        default = 14;
        description = ''
          Passed to `eza-bookmarks backup` as `EZA_BACKUP_KEEP_DAYS`. The
          command prunes backup stamp directories older than this many days;
          the systemd oneshot only performs the backup and the offsite copy.
        '';
      };

      offsite = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "eza-backups:eza";
        description = ''
          Optional offsite destination for each backup: an absolute local path
          (e.g. a mounted disk) or an rclone remote/path (contains `:`, e.g.
          `eza-backups:eza`). Local paths must be writable by the eza user.
        '';
      };
    };
  };

  # ---------------------------------------------------------------------------
  # Implementation
  # ---------------------------------------------------------------------------
  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = !cfg.caddy.enable || (cfg.caddy.hostname != null && cfg.caddy.hostname != "");
          message = "services.eza.caddy.hostname must be set when services.eza.caddy.enable is enabled.";
        }
        {
          assertion = !cfg.tailscaleServe.enable || config.services.tailscale.enable;
          message = "services.eza.tailscaleServe requires services.tailscale.enable = true.";
        }
        {
          assertion = cfg.bind != "";
          message = "services.eza.bind must be a non-empty host:port string.";
        }
        {
          assertion = cfg.enrichWorkers >= 0;
          message = "services.eza.enrichWorkers must be 0 (disabled) or greater.";
        }
        {
          assertion = cfg.fetchTimeoutMs >= 1000;
          message = "services.eza.fetchTimeoutMs must be at least 1000.";
        }
        {
          assertion = cfg.faviconMaxBytes >= 4096;
          message = "services.eza.faviconMaxBytes must be at least 4096.";
        }
        {
          assertion = cfg.faviconTtlDays >= 1;
          message = "services.eza.faviconTtlDays must be at least 1.";
        }
        {
          assertion = cfg.shareTtlDays >= 1;
          message = "services.eza.shareTtlDays must be at least 1.";
        }
        {
          assertion = cfg.backup.keepDays >= 1;
          message = "services.eza.backup.keepDays must be at least 1.";
        }
      ];

      # Fixed, non-root system user. No DynamicUser: the SQLite database and
      # snapshots must keep their uid across restarts and be readable by the
      # backup timer.
      users.groups.eza = { };
      users.users.eza = {
        isSystemUser = true;
        group = "eza";
        home = dataDir;
        description = "eza bookmark manager";
      };

      systemd.tmpfiles.rules =
        optional (!stateDirSupported) "d ${dataDir} 0750 eza eza -"
        ++ optional (
          cfg.backup.enable && cfg.backup.offsite != null && lib.hasPrefix "/" cfg.backup.offsite
        ) "d ${cfg.backup.offsite} 0700 eza eza -";

      systemd.services.eza = {
        description = "eza bookmark manager";
        documentation = [ "https://github.com/meillaya/eza" ];
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        restartTriggers =
          [ cfg.package ]
          ++ optional (cfg.staticDir == null) cfg.webAssets;

        serviceConfig = mkMerge [
          stateDirConfig
          {
            Type = "simple";
            User = "eza";
            Group = "eza";
            WorkingDirectory = dataDir;

            # SecretSpec wrapper (systemd-credential provider by default).
            ExecStart = toString secretspecRun;
            # Informational /healthz readiness probe; never fails the unit.
            ExecStartPost = "-${healthzWait}";
            Restart = "on-failure";
            RestartSec = "5s";
            TimeoutStartSec = "120s";
            TimeoutStopSec = "30s";
            KillSignal = "SIGTERM";

            Environment = [
              "EZA_DATA_DIR=${dataDir}"
              "EZA_DB=${dataDir}/eza.db"
              "EZA_BIND=${cfg.bind}"
              "PUBLIC_ORIGIN=${cfg.publicOrigin}"
              "EZA_RP_ID=${cfg.rpId}"
              "EZA_RP_NAME=${cfg.rpName}"
              "EZA_STATIC_DIR=${staticDirPath}"
              "EZA_SNAPSHOT_DIR=${dataDir}/snapshots"
              "EZA_BACKUP_DIR=${dataDir}/backups"
              "EZA_LOG_LEVEL=${cfg.logLevel}"
              "EZA_ALLOW_PRIVATE_FETCH=${boolToEnv cfg.allowPrivateFetch}"
              "EZA_ENRICH_WORKERS=${toString cfg.enrichWorkers}"
              "EZA_FETCH_TIMEOUT_MS=${toString cfg.fetchTimeoutMs}"
              "EZA_FAVICON_MAX_BYTES=${toString cfg.faviconMaxBytes}"
              "EZA_FAVICON_TTL_DAYS=${toString cfg.faviconTtlDays}"
              "EZA_SHARE_TTL_DAYS=${toString cfg.shareTtlDays}"
              "EZA_AI_PROVIDER=${cfg.aiProvider}"
              "EZA_OLLAMA_BASE_URL=${cfg.ollamaBaseUrl}"
              "EZA_AI_MODEL=${cfg.aiModel}"
              "HOME=${dataDir}"
            ];
            EnvironmentFile = optional (cfg.environmentFile != null) cfg.environmentFile;

            # Optional API keys as systemd credentials: systemd reads the files
            # as root and re-exports them at $CREDENTIALS_DIRECTORY/<name>,
            # where SecretSpec's systemd-credential provider picks them up.
            LoadCredential =
              optional (cfg.anthropicApiKeyFile != null)
                "ANTHROPIC_API_KEY:${cfg.anthropicApiKeyFile}"
              ++ optional (cfg.openaiApiKeyFile != null)
                "OPENAI_API_KEY:${cfg.openaiApiKeyFile}";

            CapabilityBoundingSet = [ "" ];
            UMask = "0027";
          }
          commonHardening
          {
            ReadWritePaths = extraReadWritePaths;
          }
        ];
      };

      # Publish the loopback Warp listener through Tailscale Serve (HTTPS).
      # Runs as root: `tailscale serve` needs the tailscaled socket.
      systemd.services.eza-tailscale-serve = mkIf cfg.tailscaleServe.enable {
        description = "Publish eza via Tailscale Serve";
        wantedBy = [ "multi-user.target" ];
        wants = [ "eza.service" ];
        after = [
          "tailscaled.service"
          "eza.service"
          "network-online.target"
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.tailscale}/bin/tailscale serve --bg --https=${toString cfg.tailscaleServe.httpsPort} http://${cfg.bind}";
          TimeoutStartSec = "60s";
        };
      };

      # Optional Caddy reverse proxy with automatic ACME HTTPS. Keep
      # publicOrigin/rpId pointed at the same hostname.
      services.caddy = mkIf (cfg.caddy.enable && cfg.caddy.hostname != null) {
        enable = true;
        virtualHosts.${cfg.caddy.hostname}.extraConfig = ''
          encode zstd gzip
          reverse_proxy ${cfg.bind}
        '';
      };

      # ---------------------------------------------------------------------
      # Backups: the server's own backup command (per-database VACUUM INTO +
      # integrity check), plus the module's offsite copy. Retention is owned by
      # the command (EZA_BACKUP_KEEP_DAYS), not by a second find pass here.
      # ---------------------------------------------------------------------
      systemd.services.eza-backup = mkIf cfg.backup.enable {
        description = "Online backup of the eza database";
        after = [ "eza.service" ];
        path = [
          pkgs.coreutils
        ] ++ optional (cfg.backup.offsite != null && !lib.hasPrefix "/" cfg.backup.offsite) pkgs.rclone;
        serviceConfig = mkMerge [
          stateDirConfig
          commonHardening
          {
            Type = "oneshot";
            User = "eza";
            Group = "eza";
            UMask = "0077";
            WorkingDirectory = dataDir;
            Environment = [
              "EZA_DATA_DIR=${dataDir}"
              "EZA_BACKUP_DIR=${dataDir}/backups"
              "EZA_BACKUP_KEEP_DAYS=${toString cfg.backup.keepDays}"
            ];
            ReadWritePaths =
              extraReadWritePaths
              ++ optional (cfg.backup.offsite != null && lib.hasPrefix "/" cfg.backup.offsite) cfg.backup.offsite;
          }
        ];
        script = ''
          set -eu
          backup_dir="${dataDir}/backups"
          mkdir -p "$backup_dir"

          # eza-bookmarks backup: consistent online copy of the control database
          # and every enabled account database (VACUUM INTO) with an integrity
          # check, followed by stamp-directory retention driven by
          # EZA_BACKUP_KEEP_DAYS (see Environment above).
          backup_line="$(${cfg.package}/bin/eza-bookmarks backup)"
          echo "$backup_line"
          first_line="$(printf '%s\n' "$backup_line" | head -n 1)"
          dest="''${first_line#backup: }"
          case "$dest" in
            /*) ;;
            *)
              echo "eza-backup: could not parse backup path from: $backup_line" >&2
              exit 1
              ;;
          esac
          if [ ! -d "$dest" ]; then
            echo "eza-backup: backup stamp directory does not exist: $dest" >&2
            exit 1
          fi
        ''
        + optionalString (cfg.backup.offsite != null) ''
          offsite=${lib.escapeShellArg cfg.backup.offsite}
          case "$offsite" in
            /*)
              mkdir -p "$offsite"
              cp -a "$dest" "$offsite/"
              echo "eza-backup: copied $dest to $offsite/"
              ;;
            *:*)
              rclone copy "$dest" "$offsite/$(basename "$dest")"
              echo "eza-backup: rclone copy $dest -> $offsite/$(basename "$dest")"
              ;;
            *)
              echo "eza-backup: services.eza.backup.offsite must be an absolute path or an rclone remote (name:path)" >&2
              exit 1
              ;;
          esac
        '';
      };

      systemd.timers.eza-backup = mkIf cfg.backup.enable {
        description = "Daily eza database backup";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.backup.schedule;
          Persistent = true;
          RandomizedDelaySec = "15m";
        };
      };
    }
  ]);
}
