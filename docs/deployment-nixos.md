# Deploying eza on NixOS

eza ships as a deployment-only Nix flake: it builds the `eza-bookmarks`
binary (Warp server + CLI), the CI-built web client bundle, a Docker image and
a hardened `services.eza` NixOS module. The development environment is
separate (`devenv.nix`, run `devenv shell`); this flake has no devShells.

The deployment binary is **eza-bookmarks**:

    eza-bookmarks serve        # start the web server (what the systemd unit runs)
    eza-bookmarks init         # create/migrate the SQLite database
    eza-bookmarks healthcheck  # GET /healthz on EZA_BIND; exit 0/1 (containers, probes)
    eza-bookmarks backup       # online backup (VACUUM INTO) + integrity check + prune
    eza-bookmarks verify       # counts + FTS consistency check
    eza-bookmarks stats        # counts + top tags
    eza-bookmarks check-dead   # dead-link sweep
    eza-bookmarks repair-domains
    eza-bookmarks import FILE [--tag-mode leaf|deepest|path|none] [--dry-run]
    eza-bookmarks bench [N]
    eza-bookmarks version

## Prerequisites

- NixOS with flakes enabled (24.11+; tested on nixos-unstable).
- A **secure origin** for passkeys: WebAuthn only works over HTTPS (or
  `http://localhost`). Use [Tailscale Serve](tailscale.md) or the module's
  Caddy option. Never expose plain HTTP to the internet.
- The web client bundle. The flake pins it as a fixed-output release asset
  (see [Web assets](#web-assets)); until CI publishes a release for your
  version you must build it locally and point the module at the local package.

## Flake input

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    eza = {
      url = "github:meillaya/eza";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, eza, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./hardware-configuration.nix
        eza.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

Or, if you keep the module in your own flake, import
`./path/to/eza/nix/module.nix` through `eza.nixosModules.default` (the module
needs its flake-provided package defaults, so always import the flake output).

## Minimal configuration (Tailscale Serve)

```nix
{ ... }:
{
  services.eza = {
    enable = true;

    # The tailnet DNS name of this machine. Find it with:
    #   tailscale status --json | jq -r .Self.DNSName
    publicOrigin = "https://eza.tail1234.ts.net";
    rpId = "eza.tail1234.ts.net";   # host without scheme/port; must stay stable

    tailscaleServe.enable = true;   # HTTPS on https://eza.tail1234.ts.net/
    backup.enable = true;           # daily online SQLite backup at 03:17
  };

  services.tailscale.enable = true;

  # Optional: AI tagging keys, loaded through SecretSpec/systemd credentials.
  # See docs/secrets.md. Files must be readable by root, e.g. agenix paths.
  # services.eza.anthropicApiKeyFile = config.age.secrets.eza-anthropic.path;
}
```

Then:

```bash
sudo nixos-rebuild switch --flake .#host
curl -fsS https://eza.tail1234.ts.net/healthz   # {"status":"ok","version":"0.1.0"}
```

Open the origin in a browser: the first visit redirects to `/setup`, where the
first account claims the installation with a username and password (later
visits go to `/login`). That account is the admin; it can add the other
accounts under Account > users. Save the one-time recovery codes shown at the
end of setup: they are the only way back in if the password is lost.
`/recover` redeems a recovery code.

## Minimal configuration (Caddy, public domain)

```nix
{
  services.eza = {
    enable = true;
    caddy = {
      enable = true;
      hostname = "eza.example.com";
    };
    # publicOrigin/rpId default to https://eza.example.com when Caddy is on.
    # DNS must point at the host and ports 80/443 must be reachable for ACME.
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
```

## Options

All options live under `services.eza`:

| Option | Default | Description |
|---|---|---|
| `enable` | `false` | Enable the service. |
| `package` | flake `eza-bookmarks` | Server package (provides `bin/eza-bookmarks`). |
| `webAssets` | flake `eza-web` (CI asset) | Bundle served at `share/eza/static`; use `eza-web-local` for local builds. |
| `dataDir` | `/var/lib/eza` | `control.db` + `users/<id>/eza.db` + `backups/`. Default is a systemd StateDirectory owned by user `eza`. |
| `bind` | `127.0.0.1:8080` | Warp listen address (`EZA_BIND`). Keep loopback behind Caddy/Tailscale. |
| `publicOrigin` | `https://<caddy.hostname>` or `http://localhost:<port>` | Browser-visible origin (`PUBLIC_ORIGIN`). Passkeys are bound to it. |
| `rpId` | host of `publicOrigin` | WebAuthn relying-party ID (`EZA_RP_ID`); host only, no scheme/port. |
| `rpName` | `eza` | Relying-party display name (`EZA_RP_NAME`). |
| `logLevel` | `info` | `EZA_LOG_LEVEL`: `debug` logs a development request line, `info` one access line per request, `warn`/`error` disable access logging. |
| `allowPrivateFetch` | `false` | `EZA_ALLOW_PRIVATE_FETCH`; permits fetching private/RFC1918 URLs. Leave off (SSRF guard). |
| `enrichWorkers` | `2` | `EZA_ENRICH_WORKERS`: in-process background enrichment workers; 0 disables them. |
| `fetchTimeoutMs` | `8000` | `EZA_FETCH_TIMEOUT_MS`: timeout per outbound fetch (server clamps below 1000). |
| `faviconMaxBytes` | `65536` | `EZA_FAVICON_MAX_BYTES`: maximum favicon download size. |
| `faviconTtlDays` | `90` | `EZA_FAVICON_TTL_DAYS`: favicon cache lifetime. |
| `shareTtlDays` | `7` | `EZA_SHARE_TTL_DAYS`: public share-link lifetime. |
| `aiProvider` | `none` | `EZA_AI_PROVIDER`: `none`, `ollama`, `openai`, `openai-compatible`, `anthropic`. |
| `ollamaBaseUrl` | `http://127.0.0.1:11434` | `EZA_OLLAMA_BASE_URL` for the `ollama` provider. |
| `aiModel` | empty | `EZA_AI_MODEL`; empty selects the provider default (`llama3.2` Ollama, `gpt-4o-mini` OpenAI, `claude-haiku-4-5` Anthropic). |
| `environmentFile` | `null` | Optional systemd EnvironmentFile path string (non-secret settings). |
| `staticDir` | `null` | Override `EZA_STATIC_DIR`; defaults to `webAssets`' `share/eza/static`. |
| `secretspecFile` | flake `secretspec.toml` | SecretSpec manifest; declares secrets, never values. |
| `secretspecProvider` | `systemd-credential` | Provider used by the wrapped ExecStart; `env` is the fallback. |
| `anthropicApiKeyFile` | `null` | Absolute path loaded as the `ANTHROPIC_API_KEY` systemd credential. |
| `openaiApiKeyFile` | `null` | Absolute path loaded as the `OPENAI_API_KEY` systemd credential. |
| `tailscaleServe.enable` | `false` | Publish the loopback listener over Tailscale Serve HTTPS. |
| `tailscaleServe.httpsPort` | `443` | Serve HTTPS port: 443, 8443 or 10000. |
| `caddy.enable` | `false` | Enable a Caddy reverse proxy with automatic ACME HTTPS. |
| `caddy.hostname` | `null` | Caddy site hostname; required when Caddy is enabled. |
| `backup.enable` | `false` | Daily SQLite backup timer. |
| `backup.schedule` | `*-*-* 03:17:00` | systemd `OnCalendar` for the timer. |
| `backup.keepDays` | `14` | Passed to `backup` as `EZA_BACKUP_KEEP_DAYS`; stamp directories older than this are pruned by the command. |
| `backup.offsite` | `null` | Absolute local path or rclone remote (`remote:path`) for an offsite copy. |

## What the unit does

`systemd.services.eza` runs as the fixed non-root user `eza` (not DynamicUser,
so the SQLite file keeps a stable owner) with `StateDirectory=eza` →
`/var/lib/eza`, mode 0750. The data directory holds:

    /var/lib/eza/control.db   account registry (identity and library paths)
    /var/lib/eza/snapshots/   legacy global snapshot root (new captures live per account)
    /var/lib/eza/users/       one library database per account
    /var/lib/eza/backups/     verified backup stamps from the timer

Environment: `EZA_DATA_DIR`, `EZA_CONTROL_DB`, `EZA_USERS_DIR`,
`EZA_MAX_USERS`, `EZA_DB` (legacy migration path only), `EZA_BIND`, `PUBLIC_ORIGIN`,
`EZA_RP_ID`, `EZA_RP_NAME`, `EZA_STATIC_DIR`, `EZA_SNAPSHOT_DIR`,
`EZA_BACKUP_DIR`, `EZA_BACKUP_KEEP_DAYS`, `EZA_LOG_LEVEL`,
`EZA_ALLOW_PRIVATE_FETCH`, `EZA_ENRICH_WORKERS`, `EZA_FETCH_TIMEOUT_MS`,
`EZA_FAVICON_MAX_BYTES`, `EZA_FAVICON_TTL_DAYS`, `EZA_FAVICON_BACKFILL`, `EZA_SHARE_TTL_DAYS`,
`EZA_AI_PROVIDER`, `EZA_OLLAMA_BASE_URL`, `EZA_AI_MODEL`, `HOME`. The
body-size and snapshot caps (`EZA_MAX_BODY_BYTES`, `EZA_IMPORT_MAX_BYTES`,
`EZA_SNAPSHOT_MAX_BYTES`) can be added through `environmentFile`.

ExecStart is wrapped by SecretSpec:

    secretspec run --file <manifest> --provider systemd-credential \
      --profile production -- <package>/bin/eza-bookmarks serve

Optional API keys are passed as systemd credentials
(`LoadCredential=NAME:/path`); SecretSpec's `systemd-credential` provider
resolves them from `$CREDENTIALS_DIRECTORY`. When no key files are configured,
the wrapper points the provider at an empty private directory (`<dataDir>/.credentials`)
so every optional secret resolves to "unset". Key-based AI providers then report
the missing key instead of failing, and `aiProvider = "ollama"` needs no key at
all. See [secrets.md](secrets.md).

After start, a non-fatal `ExecStartPost` probe waits up to 30 s, calling
`eza-bookmarks healthcheck` (which hits `GET /healthz` on `EZA_BIND`; HTTP 200
means the database answers, 503 means it does not), and logs a warning if the
server does not answer. The start itself is not blocked by the probe.

Hardening includes: `NoNewPrivileges`, `ProtectSystem=strict`,
`ProtectHome`, `PrivateTmp`, `PrivateDevices`, `ProtectKernel*/Clock/Hostname`,
`ProtectProc=invisible`, `ProcSubset=pid`, `RestrictAddressFamilies`
(AF_INET/AF_INET6/AF_UNIX), `RestrictNamespaces`, `RestrictRealtime`,
`RestrictSUIDSGID`, `LockPersonality`, `RemoveIPC`,
`SystemCallArchitectures=native`, empty `CapabilityBoundingSet`, and
`UMask=0027`.

Restart policy: `on-failure`, 5 s backoff. The unit wants
`network-online.target` (fetching bookmarks, monolith snapshots).

## Fetching, enrichment, shares and AI

Enrichment (titles, favicons, extracted text) runs on `enrichWorkers`
in-process background workers. Each worker opens its own SQLite connection
inside the server process, so there is no second systemd unit to watch; set
`enrichWorkers = 0` to disable background work entirely. Outbound requests
are bounded by `fetchTimeoutMs`, and favicons are capped at
`faviconMaxBytes` and cached for `faviconTtlDays`.

The server refuses to fetch loopback, link-local and private/RFC1918
addresses by default. `allowPrivateFetch = true` lifts that guard; only do
this only when every UI user is trusted: it lets a bookmark URL reach
loopback and private-network services that the outside world cannot see, which
is an SSRF surface rather than a normal-use setting. Public share links expire after `shareTtlDays`.

AI tagging is off by default (`aiProvider = "none"`): the AI endpoints still
answer, returning an empty suggestion list with a notice. `ollama` talks to
`ollamaBaseUrl` and needs no API key; `openai` / `openai-compatible` use the
`OPENAI_API_KEY` credential and `anthropic` uses `ANTHROPIC_API_KEY` (see
[secrets.md](secrets.md)). `aiModel` selects the model (empty means the
provider default); AI suggestions are always requested explicitly from the
record UI.

## Backups and restore

`backup.enable = true` installs `eza-backup.service` + `eza-backup.timer`
(daily at 03:17 by default). One run:

1. runs `eza-bookmarks backup` as the `eza` user with `EZA_DATA_DIR`,
   `EZA_BACKUP_DIR`, and `EZA_BACKUP_KEEP_DAYS` set: `VACUUM INTO` copies the
   control database and every account library (disabled accounts included)
   into one verified stamp directory (`<backups>/<stamp>/control.db`,
   `manifest.json`, and `<backups>/<stamp>/users/<id>/eza.db`, safe while eza
   is writing); the command prunes stamp directories older than
   `backup.keepDays`;
2. optionally copies the stamp to `backup.offsite` (absolute local path or
   rclone remote). Page snapshots are not part of a stamp; include
   `users/<id>/snapshots/` in the volume backup when they matter.

A single account can be backed up with
`eza-bookmarks backup --user <name|id>` (the control database is always
included). `eza-bookmarks users list` shows the accounts, their roles, states,
database sizes, and snapshot counts.

Restore with the service stopped (so nothing is writing). The command
validates the stamp, backs up the current installation first, restores each
library to the path in the control database, and rewrites those paths when the
data root moved:

```bash
sudo systemctl stop eza
BIN="$(nix build --no-link --print-out-paths .#eza-bookmarks)/bin/eza-bookmarks"
sudo -u eza "$BIN" restore /var/lib/eza/backups/<stamp> --yes
sudo systemctl start eza
```

`--dry-run` prints the plan without writing. A stamp from the first multi-user
layout (`users/<id>.db`, no `manifest.json`) still restores; accounts whose
library is missing from the stamp keep their current copy. Page snapshots are
not in a stamp: copy `users/<id>/snapshots/` from a volume backup when the
snapshot pages matter.

Run a backup on demand: `sudo systemctl start eza-backup.service` and check
`journalctl -u eza-backup`.

## Health checks and monitoring

`GET /healthz` is the only unauthenticated probe endpoint; use it for systemd
watchdogs, uptime monitoring and load balancers. The shipped CLI wraps it for
container/probe use:

```bash
eza-bookmarks healthcheck          # exit 0 when /healthz returns 200
curl -fsS http://127.0.0.1:8080/healthz
systemctl status eza.service
journalctl -u eza.service -f
```

## Web assets

Nix cannot build the Miso/WASM client (it needs the wasm32-wasi GHC toolchain,
which is not in nixpkgs). CI builds it with `scripts/build-web.sh` and
publishes `eza-web-<version>.tar.gz` as a GitHub release asset; the flake pins
it as a fixed-output derivation (`packages.<system>.eza-web`). The tarball must
include the `<file>.gz` sidecars the script writes next to the WASM, CSS, shell
and loader JavaScript; the server serves those with `Content-Encoding: gzip`
and `Vary: Accept-Encoding`, and without them the WASM crosses the wire at its
raw 6.7 MB instead of about 1.5 MB.

In `flake.nix` the hash is a placeholder (`lib.fakeHash`). After publishing
the asset:

```bash
nix store prefetch-file --json \
  https://github.com/meillaya/eza/releases/download/v0.1.0.0/eza-web-0.1.0.0.tar.gz
# copy the "hash" value into webAssets.hash in flake.nix, then:
nix build .#eza-web
```

For local development before the first release, build the bundle and use the
local override:

```bash
devenv shell -- scripts/build-web.sh
nix build path:.#eza-web-local      # path flake: includes gitignored static/app
# in configuration.nix:
# services.eza.webAssets = inputs.eza.packages.${system}.eza-web-local;
```

Set `services.eza.staticDir` to serve a bundle built outside Nix instead. When
it is set the unit reads that directory and does not reference `webAssets`, so
the pinned release artifact stays out of the system closure.

See [deployment-docker.md](deployment-docker.md#web-assets) for the CI
workflow and asset layout.

## Updating

```bash
# in the deployment flake
nix flake update eza
sudo nixos-rebuild switch --flake .#host
```

The module is evaluated against your `nixpkgs` because the flake input follows
it. If the web bundle is pinned by release asset hash, update the hash when the
flake version changes (or keep `webAssets` overridden to a locally built
package).

Server dependencies are pinned in the flake to the generation used by the
project's development build plan (`hpkgsUpgraded` overlay, including a few
Hackage cabal-file revisions vendored under `nix/hackage-cabal/`). If the
cabal dependencies change, update that overlay together with the release
hashes; see the comments in `flake.nix`.

## Flake outputs

| Output | Purpose |
|---|---|
| `packages.<system>.eza-bookmarks` | Server + CLI (GHC 9.10 package set, local core/server). |
| `packages.<system>.eza-web` | CI-built web bundle (fixed-output release asset). |
| `packages.<system>.eza-web-local` | Local bundle from `./static` (development override). |
| `packages.<system>.docker` | Layered Docker image tarball from the CI web asset (non-root, `/data`, `eza-bookmarks healthcheck`). |
| `packages.<system>.docker-local` | Same image built with the local `./static` bundle (before the first release asset). |
| `nixosModules.default` | `services.eza` module (this page). |
| `checks.<system>.eza-module` | Cheap module evaluation/security-posture check. |
| `checks.<system>.nixos-vm` | Full NixOS VM test (builds a system image; needs KVM for speed). |

Validate a configuration before switching:

> Working from the eza repo while the rewrite is still uncommitted? Nix's git
> flake source only contains tracked files, so paths like `core/` or
> `deploy/` can be missing. Use an explicit path flake for local builds:
> `nix build path:.#eza-bookmarks`, `nix build path:.#docker-local`, ...
> Once the tree is committed, plain `.#...` references work everywhere.

```bash
# Fast: module evaluation + unit-file/hardening assertions (no server build).
nix build .#checks.${system}.eza-module

# Full VM test: builds the server package and a complete NixOS system, boots
# it under QEMU and probes /healthz + the backup timer. Heavy (needs KVM for
# reasonable runtime).
nix build .#checks.${system}.nixos-vm

# Everything at once: evaluates all outputs and builds both checks above.
# Note: `nix flake check --no-build` does NOT work for this flake because
# `callCabal2nix` uses import-from-derivation (tiny cabal2nix derivations must
# be built during evaluation).
nix flake check
```

## Troubleshooting

| Symptom | Check |
|---|---|
| Unit fails immediately | `journalctl -u eza.service`; usually an unreadable `LoadCredential` path or an invalid origin. |
| `/healthz` 503 | Database path/dataDir permissions; `sudo -u eza ls -l /var/lib/eza`. |
| Passkey registration fails | `publicOrigin`/`rpId` must exactly match the browser URL; must be HTTPS. |
| 502 from Caddy/Tailscale | `bind` must be a loopback address the proxy can reach, unit must be running. |
| Web client 404 / blank | `webAssets` empty or wrong; check `EZA_STATIC_DIR` in `systemctl show eza`. |
| Backup timer silent | `systemctl list-timers eza-backup.timer`; `journalctl -u eza-backup`. |
