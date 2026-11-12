{
  description = "eza: self-hosted, tag-based bookmark manager (Haskell/Warp server, SQLite+FTS5, Miso web client). Deployment flake: server package, web assets, Docker image, NixOS module.";

  # Deployment-only flake: there is deliberately NO devShells output here.
  # The development environment is devenv.nix (run: devenv shell). This flake
  # is what operators build and import into a NixOS configuration.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = lib.genAttrs systems;

      version = "0.2.0.0";

      # ---------------------------------------------------------------------
      # Web assets (the static/ tree: index.html, eza.css, theme.js, and the
      # app/ directory holding app.wasm + its JS loader).
      #
      # The Miso client is built with the wasm32-wasi GHC toolchain, which is
      # not part of nixpkgs; Nix therefore cannot build it. CI runs
      # scripts/build-web.sh with that toolchain and publishes the resulting
      # static/ tree as the release asset referenced below. This flake pins
      # the asset as a fixed-output derivation -- the CI-built asset IS the
      # fixed output.
      #
      # The URL and SRI hash live in nix/web-assets.json: exactly one file to
      # edit on a release. .github/workflows/release.yml builds and uploads
      # eza-web-<version>.tar.gz on a v* tag and rewrites that file with the
      # uploaded asset's hash; scripts/release-asset.sh builds the same
      # deterministic tarball locally and prints the SRI hash. Until the hash
      # is pinned, packages.<system>.eza-web (and therefore .#docker and the
      # default NixOS module path) fails with an actionable message; use
      # packages.<system>.eza-web-local / .#docker-local in the meantime.
      # docs/deployment-docker.md and docs/deployment-nixos.md describe the
      # operator-facing release sequence.
      # ---------------------------------------------------------------------
      webAssets = builtins.fromJSON (builtins.readFile ./nix/web-assets.json);

      expectedWebAssetUrl =
        "https://github.com/meillaya/eza/releases/download/v${version}/eza-web-${version}.tar.gz";

      webAssetsPinned = webAssets.hash != lib.fakeHash;

      # The failure operators see when a release asset has not been published
      # yet. Kept next to the pin so there is one place to explain the process.
      webAssetsUnpinnedMessage = ''
        eza-web: the pinned web bundle asset is not available yet.

        nix/web-assets.json still carries the lib.fakeHash placeholder for:
          ${webAssets.url}

        Publish the release asset (or run `bash scripts/release-asset.sh`),
        then pin its SRI hash in nix/web-assets.json:
          "hash": "<nix hash file --sri --type sha256 eza-web-${version}.tar.gz>"

        Before the first release asset, build the bundle locally and use the
        local override instead:
          bash scripts/build-web.sh
          nix build path:.#eza-web-local
          nix build path:.#docker-local
      '';

      # NixOS module: nix/module.nix is a normal module; this wrapper injects
      # the pinned package defaults through _module.args.
      ezaModule =
        { pkgs, ... }:
        let
          system = pkgs.stdenv.hostPlatform.system;
        in
        {
          _module.args = {
            ezaPackage = self.packages.${system}.eza-bookmarks;
            ezaWebAssets = self.packages.${system}.eza-web;
            secretspecManifest = ./secretspec.toml;
          };
          imports = [ ./nix/module.nix ];
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          hpkgs = pkgs.haskell.packages.ghc910;

          # --- server + CLI (local packages, nixpkgs GHC 9.10 package set) ---
          eza-core = hpkgs.callCabal2nix "eza-core" ./core { };

          # --- server dependency versions (development build plan) -------------
          # The server's passkey layer uses webauthn 0.12 + crypton 1.1, which
          # nixpkgs' GHC 9.10 Hackage snapshot does not ship (it only has
          # webauthn 0.11, marked broken because it cannot build with GHC 9.10's
          # core libraries). The server is therefore built against the exact
          # dependency generation from the project's development build plan:
          # crypton 1.1.5 / crypton-x509 1.9 / tls 2.4 / http2 5.4 plus the
          # packages those require. The nixpkgs versions cannot be mixed in:
          # Cabal aborts when one build plan needs two major versions of the
          # same package, so the whole network/crypto stack is overlaid at once
          # and everything else keeps the nixpkgs-pinned version.
          #
          # Each entry is a Hackage release fetched by SRI hash. Bump this set
          # together with the cabal dependency changes; compute a hash with:
          #   nix store prefetch-file --json https://hackage.haskell.org/package/<pkg>-<ver>/<pkg>-<ver>.tar.gz
          #
          # cabal2nix wants an unpacked source tree (given a tarball it shells
          # out to nix-prefetch-url, which is not available in its build), so
          # each tarball is a fixed-output fetchurl and the unpacked tree is a
          # trivial derivation.
          #
          # Some of these releases need their published *Hackage revision*:
          # the .cabal file inside the release tarball still has the original
          # bounds (e.g. crypton-connection rejects tls 2.4, crypton-x509
          # rejects crypton 1.1) while the revision relaxes them for this
          # dependency generation. The revised files were exported verbatim
          # from the Hackage 01-index.tar the devenv cabal solver used and are
          # kept in nix/hackage-cabal/; they are copied over the tarball's
          # cabal file before cabal2nix runs.
          hackageSrc = pkg: ver: hash:
            let
              revisedCabal = (./nix/hackage-cabal) + "/${pkg}-${ver}.cabal";
            in
            pkgs.runCommand "${pkg}-${ver}-src" { } (
              ''
                mkdir -p $out
                tar -xzf "${pkgs.fetchurl {
                  name = "${pkg}-${ver}.tar.gz";
                  url = "https://hackage.haskell.org/package/${pkg}-${ver}/${pkg}-${ver}.tar.gz";
                  inherit hash;
                }}" -C $out --strip-components=1
              ''
              + lib.optionalString (builtins.pathExists revisedCabal) ''
                cp ${revisedCabal} "$out/${pkg}.cabal"
              ''
            );

          # Build a pinned Hackage library without its test suites. The nixpkgs
          # Haskell builder enables tests by default (doCheck = !isCross) and
          # some of these releases have tests that fail in the sandbox or need
          # extra tooling; only the library is needed here.
          hackagePkg = self: pkg: ver: hash:
            pkgs.haskell.lib.overrideCabal
              (self.callCabal2nix pkg (hackageSrc pkg ver hash) { })
              (orig: { doCheck = false; });

          hpkgsUpgraded = hpkgs.extend (self: super: {
            crypton = hackagePkg self "crypton" "1.1.5" "sha256-vP+EalN0Keqj1kweqIjC37JIBcs62c5sV7GuDzlGI5Q=";
            crypton-connection = hackagePkg self "crypton-connection" "0.4.6" "sha256-1oa3hVgX6oxLyN73m3i8JK73JZc+gqiv0QnVKMnFQDQ=";
            crypton-x509 = hackagePkg self "crypton-x509" "1.9.1" "sha256-VSYCkDOCclYrexRSAC4a0Nm2uS+zHcJfYRX10to8vA4=";
            crypton-x509-store = hackagePkg self "crypton-x509-store" "1.9.0" "sha256-3pGTQDwR0fsJAIM4Jka+b2z2jtmE9HXRoOFC9377h2Y=";
            crypton-x509-system = hackagePkg self "crypton-x509-system" "1.9.0" "sha256-ie6Bm3iWOlySX9qtgOLmS+bA/t9PJPwrle3bZJuGzv4=";
            crypton-x509-validation = hackagePkg self "crypton-x509-validation" "1.9.1" "sha256-j8uDQBEUx/aU2ExUPo9/ls6mDFQ6MKdwkDdB0zbuzj0=";
            hpke = hackagePkg self "hpke" "0.2.0" "sha256-dyDnQC5bg6u/wi7JiqPjqwCCZOMswGtLzbnelQEmkt0=";
            http-client-tls = hackagePkg self "http-client-tls" "0.4.0" "sha256-YRzxTPBGZXuxeIpNrAlxC0sQTAN9QrGJFIwC5t2Erjw=";
            http-semantics = hackagePkg self "http-semantics" "0.4.2" "sha256-iIth1K6bZHNEbkki04wcNb5JnLnCwGrenD7291hXGwc=";
            http-types = hackagePkg self "http-types" "0.12.6" "sha256-togEKstOU/H17+0mBWzx/cOuXca4XPvjIe3/wwecEGw=";
            http2 = hackagePkg self "http2" "5.4.13" "sha256-WZbpyfq5cQNoXiDH68iBvhKmuHlQNDB3CENGupiD5zc=";
            jose = hackagePkg self "jose" "0.13" "sha256-OuImujBY6vDAAxhFlp2N1+oWO+9NNOg1X8CaVyNXX1k=";
            mlkem = hackagePkg self "mlkem" "0.2.3.0" "sha256-u2sk/PM30EgKZMi1FS2X7PKCCHKCTXkqtGqftFrLCCk=";
            network = hackagePkg self "network" "3.2.12.0" "sha256-yPASjlfUFJeuncTmQW1FxoSnqNqqzHrp9U4EcWOG2Rk=";
            recv = hackagePkg self "recv" "0.1.3" "sha256-Y1+lxvw2LjUSHE0zXVpKlLv4zanqP3fdmYT3rnxkeMU=";
            time-manager = hackagePkg self "time-manager" "0.5.2" "sha256-Sfigdv9vF5WBoFDVn+ez+lpK1NczLXSjjBcaO5T0Zoc=";
            tls = hackagePkg self "tls" "2.4.6" "sha256-YPUxo4GJgRg8+7ohr8VKuZydUyGjHxK4CD4sWIPx528=";
            wai = hackagePkg self "wai" "3.2.5" "sha256-et0Z9TcaGFD414XbJAHtsUTfsnVaexrE0jN+vHce1Go=";
            warp = hackagePkg self "warp" "3.4.21" "sha256-/lGA2G08FrxhHJU1OVynGJ1eI6hlHUPi88TdJPOvYmM=";
            webauthn = hackagePkg self "webauthn" "0.12.0.0" "sha256-nheT2/kPMTKJMPQvMTnKd3suaXE/ci7KezPRfILgga8=";
          });

          # The server's hspec suite reads fixtures from ../tests/fixtures,
          # which are outside the server package source; run tests from the
          # dev environment (cabal test all), not during the package build.
          eza-server = pkgs.haskell.lib.overrideCabal
            (hpkgsUpgraded.callCabal2nix "eza-server" ./server {
              eza-core = eza-core;
            })
            (orig: { doCheck = false; });

          # justStaticExecutables drops the propagated Haskell library/doc
          # closure: the deployment only needs the executable, and shipping the
          # GHC libraries + Haddock docs would bloat the Docker image to ~800 MB.
          eza-bookmarks = (pkgs.haskell.lib.justStaticExecutables eza-server).overrideAttrs (old: {
            meta = (old.meta or { }) // {
              description = "eza bookmark manager (Warp server + command-line tools)";
              homepage = "https://github.com/meillaya/eza";
              license = lib.licenses.asl20;
              mainProgram = "eza-bookmarks";
              platforms = lib.platforms.linux;
            };
          });

          # --- web assets ----------------------------------------------------
          # CI-built release asset, fetched and unpacked to a stable location
          # that EZA_STATIC_DIR can point at. While the pin is the
          # lib.fakeHash placeholder the derivation throws with the release
          # instructions rather than failing on a hash mismatch after a
          # network fetch; .#docker and the default module path inherit it.
          eza-web-asset =
            if webAssetsPinned then
              pkgs.fetchurl {
                name = "eza-web-${version}.tar.gz";
                inherit (webAssets) url hash;
              }
            else
              throw webAssetsUnpinnedMessage;

          eza-web = pkgs.runCommand "eza-web-${version}" {
            meta.description = "eza web client bundle (CI-built release asset)";
          } ''
            mkdir -p $out/share/eza/static
            tar -xzf ${eza-web-asset} -C $out/share/eza/static
            # The bundle must contain the WASM client and its precompressed
            # sidecars; an empty/incorrect tarball should fail here, not in a
            # browser.
            test -f $out/share/eza/static/index.html
            test -f $out/share/eza/static/app/app.wasm
            test -f $out/share/eza/static/app/app.wasm.gz
          '';

          # Local override: package the working tree's static/ directory
          # instead of the release asset. `static/app` is a build artifact and
          # is gitignored, so build it first (devenv shell -- scripts/build-web.sh)
          # and either use `nix build path:.#eza-web-local` (a path flake sees
          # untracked files) or stage the bundle (git add -f static/app).
          eza-web-local =
            let
              localStatic = ./static;
              hasBundle = builtins.pathExists (localStatic + "/app");
            in
            pkgs.runCommand "eza-web-local-${version}" { } (
              if hasBundle then
                ''
                  mkdir -p $out/share/eza/static
                  cp -r ${localStatic}/. $out/share/eza/static/
                ''
              else
                ''
                  echo "eza-web-local: no static/app directory in the flake source." >&2
                  echo "Build the bundle first: devenv shell -- scripts/build-web.sh" >&2
                  echo "Then build from a path flake (nix build path:.#eza-web-local)" >&2
                  echo "or stage the gitignored bundle: git add -f static/app" >&2
                  exit 1
                ''
            );

          # --- container image ----------------------------------------------
          # The secretspec manifest ships read-only for the optional
          # `secretspec run --provider env` wrapper (see docs/deployment-docker.md).
          eza-etc = pkgs.runCommand "eza-etc" { } ''
            mkdir -p $out/etc/eza
            cp ${./secretspec.toml} $out/etc/eza/secretspec.toml
            chmod 0444 $out/etc/eza/secretspec.toml
          '';

          # uid/gid 10001 is the unprivileged runtime identity. /data is
          # pre-created with that ownership (fakeRootCommands runs under
          # fakeroot) so a fresh named volume is writable without a manual
          # chown.
          mkDocker = web: pkgs.dockerTools.buildLayeredImage {
            name = "eza";
            tag = version;
            contents = [
              eza-bookmarks
              web
              eza-etc
              pkgs.bash
              pkgs.cacert
              pkgs.coreutils
              pkgs.curl
              pkgs.monolith
              pkgs.rclone
              pkgs.secretspec
              pkgs.sqlite
            ];
            fakeRootCommands = ''
              mkdir -p data
              chmod 0750 data
              chown 10001:10001 data
            '';
            config = {
              Cmd = [ "${eza-bookmarks}/bin/eza-bookmarks" "serve" ];
              User = "10001:10001";
              WorkingDir = "/data";
              Env = [
                "EZA_DATA_DIR=/data"
                "EZA_BIND=0.0.0.0:8080"
                "EZA_STATIC_DIR=${web}/share/eza/static"
                "PUBLIC_ORIGIN=http://localhost:8080"
                "EZA_LOG_LEVEL=info"
                "HOME=/data"
                "LANG=C.UTF-8"
                "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
                "PATH=${lib.makeBinPath [
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.curl
                  pkgs.monolith
                  pkgs.rclone
                  pkgs.secretspec
                  pkgs.sqlite
                ]}"
                "SECRETSPEC_FILE=/etc/eza/secretspec.toml"
              ];
              ExposedPorts = {
                "8080/tcp" = { };
              };
              Volumes = {
                "/data" = { };
              };
              Healthcheck = {
                # eza-bookmarks healthcheck: GET /healthz on EZA_BIND (200 =
                # healthy, 503 when the database is unavailable).
                Test = [
                  "CMD"
                  "${eza-bookmarks}/bin/eza-bookmarks"
                  "healthcheck"
                ];
                Interval = 30 * 1000000000;
                Timeout = 5 * 1000000000;
                StartPeriod = 15 * 1000000000;
                Retries = 5;
              };
            };
          };

          # Release image: server + the CI-built web asset pinned in webAssets.
          docker = mkDocker eza-web;
          # Local image: server + the bundle built from ./static (useful before
          # the first release asset exists, and for CI smoke tests).
          docker-local = mkDocker eza-web-local;
        in
        {
          inherit eza-bookmarks eza-web eza-web-local docker docker-local;
          eza-core = eza-core;
          eza-server = eza-server;
          default = eza-bookmarks;
        }
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.eza-bookmarks}/bin/eza-bookmarks";
          meta.description = "Run the eza bookmark manager";
        };
        eza-bookmarks = {
          type = "app";
          program = "${self.packages.${system}.eza-bookmarks}/bin/eza-bookmarks";
          meta.description = "Run the eza bookmark manager";
        };
      });

      nixosModules = {
        default = ezaModule;
        eza = ezaModule;
      };

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # Stand-in for the CI-built release asset so checks never need the
          # real (network) fixed-output derivation.
          stubWeb = pkgs.runCommand "eza-web-stub" { } ''
            mkdir -p $out/share/eza/static
            printf '%s\n' '<!doctype html><title>eza</title>' > $out/share/eza/static/index.html
          '';

          # Minimal stand-ins so the module check never builds the real server
          # package or fetches the fixed-output web asset.
          stubPackage = pkgs.writeShellScriptBin "eza-bookmarks" ''
            echo "stub eza-bookmarks package (module evaluation check)"
          '';

          nixosConfig = lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.default
              {
                services.eza = {
                  enable = true;
                  package = stubPackage;
                  webAssets = stubWeb;
                  publicOrigin = "http://localhost:8080";
                  rpId = "localhost";
                  backup.enable = true;
                };
              }
            ];
          };

          unitText = nixosConfig.config.systemd.units."eza.service".text;
          backupUnitText = nixosConfig.config.systemd.units."eza-backup.service".text;
        in
        {
          # Cheap check: forces the full NixOS module evaluation (assertions,
          # systemd unit rendering, users, tmpfiles) and asserts the security
          # posture without building a system.
          #
          # ExecStart/ExecStartPost point at wrapper scripts in the store. grep
          # reads the *contents* of a file argument, so the wrapper paths are
          # resolved and copied first; the generated scripts single-quote some
          # arguments (lib.escapeShellArg) and not others, so quotes are
          # stripped before matching. The previous version grep'd for
          # `--provider systemd-credential` while the wrapper contains
          # `--provider 'systemd-credential'`, which is why this check failed
          # for every system.
          eza-module = pkgs.runCommand "eza-module-check" {
            inherit expectedWebAssetUrl;
            pinUrl = webAssets.url;
            pinHash = webAssets.hash;
            pinPinned = if webAssetsPinned then "1" else "0";
            staticDirExpected = "${stubWeb}/share/eza/static";
          } ''
            mkdir -p $out
            fail() {
              echo "eza-module check failed: $*" >&2
              exit 1
            }
            cat > $out/eza.service <<'UNIT'
            ${unitText}
            UNIT

            # Unit structure and hardening posture.
            grep -Fq 'StateDirectory=eza' $out/eza.service || fail 'StateDirectory=eza missing'
            grep -Fq 'StateDirectoryMode=0750' $out/eza.service || fail 'StateDirectoryMode=0750 missing'
            grep -Fq 'User=eza' $out/eza.service || fail 'User=eza missing'
            grep -Fq 'NoNewPrivileges=true' $out/eza.service || fail 'NoNewPrivileges missing'
            grep -Fq 'ProtectSystem=strict' $out/eza.service || fail 'ProtectSystem=strict missing'
            grep -Fq 'RestrictNamespaces=true' $out/eza.service || fail 'RestrictNamespaces missing'
            grep -Fq 'EZA_DATA_DIR=/var/lib/eza' $out/eza.service || fail 'EZA_DATA_DIR wrong'
            grep -Fq "EZA_STATIC_DIR=$staticDirExpected" $out/eza.service \
              || fail "EZA_STATIC_DIR does not point at the webAssets package ($staticDirExpected)"
            grep -Fq 'ExecStartPost=-' $out/eza.service || fail 'ExecStartPost=- missing'

            # ExecStart is the SecretSpec wrapper, configured for systemd
            # credentials and the production profile. Read the wrapper file
            # itself (not the path string) and normalise the shell quoting.
            exe=$(sed -n 's/^ExecStart=//p' $out/eza.service)
            [ -n "$exe" ] || fail 'no ExecStart= line in eza.service'
            test -x "$exe" || fail "ExecStart is not an executable wrapper: $exe"
            cat "$exe" > $out/eza-secretspec-run
            tr -d "'" < $out/eza-secretspec-run > $out/eza-secretspec-run.txt
            grep -Fq 'secretspec run' $out/eza-secretspec-run.txt || fail 'wrapper does not run secretspec'
            grep -Fq -- '--file' $out/eza-secretspec-run.txt || fail 'wrapper has no --file'
            grep -Fq -- '--provider systemd-credential' $out/eza-secretspec-run.txt \
              || fail "wrapper provider is not systemd-credential: $(cat $out/eza-secretspec-run.txt)"
            grep -Fq -- '--profile production' $out/eza-secretspec-run.txt \
              || fail 'wrapper profile is not production'
            grep -Fq 'bin/eza-bookmarks serve' $out/eza-secretspec-run.txt \
              || fail 'wrapper does not exec eza-bookmarks serve'

            # The startup probe uses the server's own healthcheck command.
            probe=$(sed -n 's/^ExecStartPost=-//p' $out/eza.service)
            [ -n "$probe" ] || fail 'no ExecStartPost= line in eza.service'
            test -x "$probe" || fail "ExecStartPost is not an executable wrapper: $probe"
            cat "$probe" > $out/eza-healthz-wait
            grep -Fq 'eza-bookmarks healthcheck' $out/eza-healthz-wait \
              || fail 'startup probe does not call eza-bookmarks healthcheck'

            # The backup oneshot delegates to the server's backup command and
            # runs as the unprivileged user.
            cat > $out/eza-backup.service <<'UNIT'
            ${backupUnitText}
            UNIT
            grep -Fq 'User=eza' $out/eza-backup.service || fail 'backup unit User=eza missing'
            grep -Fq 'Type=oneshot' $out/eza-backup.service || fail 'backup unit Type=oneshot missing'
            grep -Fq 'WorkingDirectory=/var/lib/eza' $out/eza-backup.service || fail 'backup WorkingDirectory wrong'
            grep -Fq 'EZA_DATA_DIR=/var/lib/eza' $out/eza-backup.service || fail 'backup EZA_DATA_DIR wrong'
            grep -Fq 'EZA_BACKUP_DIR=/var/lib/eza/backups' $out/eza-backup.service || fail 'backup EZA_BACKUP_DIR wrong'
            grep -Fq 'EZA_BACKUP_KEEP_DAYS=14' $out/eza-backup.service || fail 'backup keep-days wrong'
            backup_script=$(sed -n 's/^ExecStart=//p' $out/eza-backup.service | sed 's/[[:space:]]*$//')
            [ -n "$backup_script" ] || fail 'no backup ExecStart='
            test -x "$backup_script" || fail "backup ExecStart is not executable: $backup_script"
            cat "$backup_script" > $out/eza-backup
            grep -Fq 'eza-bookmarks backup' $out/eza-backup || fail 'backup script does not call eza-bookmarks backup'
            # The command owns retention and writes a stamp directory; the unit
            # must not run a second find-based retention pass.
            ! grep -Fq -- '-mtime' $out/eza-backup || fail 'backup unit runs its own retention pass'

            # Web-asset pin: the module path serves the flake's fixed-output
            # CI bundle, so its URL must name this flake version and its hash
            # must be a syntactically valid SRI sha256. The real value lives in
            # nix/web-assets.json; checks.eza-web-pin fails while it is the
            # placeholder (this check still passes so the security posture is
            # testable before the first release asset).
            [ "$pinUrl" = "$expectedWebAssetUrl" ] || fail "nix/web-assets.json url is '$pinUrl', expected '$expectedWebAssetUrl'"
            printf '%s' "$pinHash" | grep -Eq '^sha256-[A-Za-z0-9+/]{43}=$' \
              || fail "nix/web-assets.json hash is not an SRI sha256: $pinHash"
            if [ "$pinPinned" != "1" ]; then
              echo "eza-module: warning: nix/web-assets.json still pins the lib.fakeHash placeholder." >&2
              echo "  checks.eza-web-pin fails until the release asset hash is set." >&2
            fi

            touch $out/ok
          '';

          # Fails while nix/web-assets.json carries the lib.fakeHash
          # placeholder. Default builds (.eza-web, .#docker, the default NixOS
          # module path) cannot produce a real bundle until the release asset
          # exists; this check makes that state visible instead of a
          # fixed-output hash mismatch. Run release.yml, then the hash pin
          # turns this check green.
          eza-web-pin = pkgs.runCommand "eza-web-pin-check" {
            inherit expectedWebAssetUrl;
            pinnedUrl = webAssets.url;
            pinnedHash = webAssets.hash;
          } (
            if webAssetsPinned then
              ''
                mkdir -p $out
                [ "$pinnedUrl" = "$expectedWebAssetUrl" ] || {
                  echo "eza-web-pin: nix/web-assets.json url is '$pinnedUrl', expected '$expectedWebAssetUrl'" >&2
                  exit 1
                }
                printf '%s\n' "$pinnedUrl" > $out/url
                printf '%s\n' "$pinnedHash" > $out/hash
                touch $out/ok
              ''
            else
              ''
                echo "eza-web-pin check failed: nix/web-assets.json still pins lib.fakeHash." >&2
                echo "" >&2
                cat > $out/unpinned-message <<'MSG'
                ${webAssetsUnpinnedMessage}
                MSG
                cat $out/unpinned-message >&2
                exit 1
              ''
          );

          # Full NixOS VM test (best effort: builds the server package and a
          # complete system image; needs KVM to run quickly). Covers health
          # endpoint, data-dir creation and the backup oneshot.
          nixos-vm = pkgs.testers.runNixOSTest {
            name = "eza-nixos-vm";
            nodes.machine =
              { pkgs, ... }:
              {
                imports = [ self.nixosModules.default ];
                system.stateVersion = "25.05";
                services.eza = {
                  enable = true;
                  webAssets = stubWeb;
                  publicOrigin = "http://localhost:8080";
                  rpId = "localhost";
                  backup.enable = true;
                };
                environment.systemPackages = [
                  pkgs.curl
                  pkgs.sqlite
                ];
              };
            testScript = ''
              machine.start()
              machine.wait_for_unit("eza.service")
              machine.wait_for_open_port(8080)
              machine.succeed("curl -fsS http://127.0.0.1:8080/healthz")
              # Multi-user layout: the control database owns identity and the
              # per-account libraries live under users/<id>/eza.db. A fresh
              # install has no accounts until /setup is claimed.
              machine.succeed("test -f /var/lib/eza/control.db")
              machine.succeed("test -d /var/lib/eza/users")
              machine.succeed("systemctl show eza.service -p User --value | grep -qx eza")
              machine.succeed("systemctl show eza.service -p NoNewPrivileges --value | grep -qx yes")
              # The backup oneshot writes one stamp directory per run holding
              # control.db and the users/ subtree.
              machine.succeed("systemctl start eza-backup.service")
              machine.succeed("find /var/lib/eza/backups -mindepth 1 -maxdepth 1 -type d | grep -q .")
              machine.succeed("test -f $(find /var/lib/eza/backups -mindepth 1 -maxdepth 1 -type d | head -n1)/control.db")
              machine.succeed("test -d $(find /var/lib/eza/backups -mindepth 1 -maxdepth 1 -type d | head -n1)/users")
              machine.succeed("sqlite3 $(find /var/lib/eza/backups -mindepth 1 -maxdepth 1 -type d | head -n1)/control.db 'PRAGMA integrity_check;' | grep -qx ok")
            '';
          };
        }
      );
    };
}
