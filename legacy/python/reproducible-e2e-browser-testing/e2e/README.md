# e2e — Reproducible Playwright/Chromium browser testing

This directory documents how the repository's Playwright end-to-end suite
(`tests/e2e/`, 9 specs + 2 helpers) can be run **reproducibly anywhere**: in a
pinned Docker image, in a Nix devshell, in CI, and — via the runbooks below —
on Railway cron, on a bare-metal server, and on CachyOS/Arch Linux.

The goal is a setup you can copy into **any** project, plus runbooks tuned to
this repository's actual artifacts. Everything here was verified by execution;
browser revisions are locked to `@playwright/test@1.62.1` so they can never
silently drift from the local suite.

## Artifact inventory (what this repo actually ships)

| Artifact                          | Purpose                                                                                                                                                                                                                                                                                                                                                     |
| --------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Dockerfile.e2e`                  | Pinned runner image: `mcr.microsoft.com/playwright:v1.62.1-noble` + Bun `1.3.11` (matches `packageManager`), non-root `pwuser` (uid 1001) with a writable `/work`, `PLAYWRIGHT_BROWSERS_PATH=/ms-playwright`, `PLAYWRIGHT_INCLUDE_WEBKIT=1` scoped to container environments only.                                                                          |
| `docker-compose.yml`              | Runner-only topology (Topology B, see §1.3): one `e2e` service, `user: root` (host bind mounts are not writable by uid 1001), `ipc: host`, `init: true`, named volumes for `/work/test-results` and `/work/playwright-report`. `PLAYWRIGHT_BASE_URL` is deliberately **unset** so the config's own `webServer` builds + boots the app inside the container. |
| `.devcontainer/devcontainer.json` | Same pinned image + `PLAYWRIGHT_INCLUDE_WEBKIT=1`, `PLAYWRIGHT_BROWSERS_PATH=/ms-playwright`, noVNC desktop (`desktop-lite`) for codegen, forwarded ports 6080/9323, Bun 1.3.11 via `postCreateCommand`.                                                                                                                                                    |
| `.github/workflows/e2e.yml`       | GitHub Actions `container:`-block workflow on the pinned image (`--user 1001`), Bun 1.3.11, `bun install --frozen-lockfile`, `bun run test:e2e`, artifact upload on failure. Its equivalent container commands are reproduced in §1.5 so the flow is verifiable even where Actions doesn't exist.                                                           |
| `flake.nix` / `flake.lock`        | Nix devshell pinning `nixpkgs-playwright` at `590d737e` (PR #550089 head — the only rev shipping Playwright 1.62.1 with byte-identical browsers), `PLAYWRIGHT_BROWSERS_PATH` → the nix store linkFarm, and a kellnr-style `shellHook` guard that fails loudly if `package.json`'s `@playwright/test` drifts from `playwright-driver.version`.               |
| `playwright.config.ts`            | The repository's own config — the reference implementation of the contract described in §1.4. Honors `PLAYWRIGHT_BASE_URL` (set → `webServer` skipped, line 7-9), injects the harness env when it boots the standalone server itself (lines 24-36), CI-aware retries (line 81).                                                                             |

Run everything from the repo root with `bun run test:e2e`. The full local
chromium suite is 48 tests across 9 specs; `PLAYWRIGHT_INCLUDE_WEBKIT=1` (CI,
container, or Nix devshell) also enables the `webkit-mobile-smoke` project.

---

## 1. The five-file contract (for OTHER projects)

> **This repository does not adopt the config-factory or fixture layer.**
> Its own `playwright.config.ts` already implements the same contract natively
> (explicit `baseURL`, a self-booting `webServer`, project-dependency setup,
> CI-aware retries) and its specs import from `@playwright/test` directly.
> Nothing in `tests/e2e/` was changed to fit the template.
> **The five-file contract below is the template to copy into a NEW project.**
> This repo is only a working reference for the first three files.

Any project that wants Playwright e2e testing to "just work" for any developer
(host machine, container, CI, cloud) should assemble these **five files**:

### 1.1 `.devcontainer/devcontainer.json` — the developer entry point

One pinned image, one command to get a reproducible environment:

```json
{
  "name": "e2e",
  "image": "mcr.microsoft.com/playwright:v1.62.1-noble",
  "containerEnv": {
    "PLAYWRIGHT_BROWSERS_PATH": "/ms-playwright"
  },
  "postCreateCommand": "bun install --frozen-lockfile",
  "customizations": {
    "vscode": { "extensions": ["ms-playwright.playwright"] }
  }
}
```

Opening the repo in VS Code with Dev Containers drops the developer into the
same browser binaries CI uses. No local install, no drift.

### 1.2 `docker-compose.yml` — the local runner

Two topologies, both shown below. **Topology A** (app-under-test + runner) is
the generic cross-project pattern: the app runs in its own service and the
runner points at it via `PLAYWRIGHT_BASE_URL`. **Topology B** (runner-only) is
what THIS repo uses — it is only viable when the project's own config boots the
app server itself (this repo's `webServer` builds the standalone Next server
and injects the harness env, so no app service is needed).

Topology A (generic, for other projects):

```yaml
services:
  app:
    build: .
    ports: ["3000:3000"]
  e2e:
    image: mcr.microsoft.com/playwright:v1.62.1-noble
    depends_on:
      app:
        condition: service_healthy
    ipc: host
    init: true
    environment:
      PLAYWRIGHT_BASE_URL: http://app:3000
    volumes:
      - .:/work
    working_dir: /work
```

Topology B (what this repo ships, in `docker-compose.yml`): one `e2e` service,
`user: root` (host bind mounts aren't writable by the image's uid 1001),
`ipc: host`, `init: true`, `PLAYWRIGHT_BASE_URL` **unset** so the config's
built-in `webServer` builds and starts the app inside the runner.

### 1.3 One image / one flake — used by CI AND local

The same pinned browser set everywhere:

- **Docker route**: `Dockerfile.e2e` based on `mcr.microsoft.com/playwright:v1.62.1-noble` (browsers prebaked at `/ms-playwright`, byte-matching `@playwright/test@1.62.1`). CI runs the same image via the workflow `container:` block; local dev runs it via compose or the devcontainer. **Never use an unpinned floating tag** — the unversioned tag alias on this image is stale (2024-08) and would drift from the pinned test version. Always reference the exact `v1.62.1-noble` revision.
- **Nix route**: `flake.nix` with a second `nixpkgs-playwright` input pinned at the exact rev that ships Playwright 1.62.1. Local `nix develop` produces the same browser revisions as npm's 1.62.1 and the Docker image.

Rule of thumb: pick **one** image/flake per project and make CI, compose, and
devcontainer all reference that same pinned revision.

### 1.4 The config-factory `playwright.config.ts` — the contract in code

A reusable config factory should always express:

- **Explicit `baseURL`** — from `PLAYWRIGHT_BASE_URL` when set (so external
  deployments like Railway don't need the runner to boot an app), falling back
  to `http://localhost:3000`.
- **A `webServer` array** — one entry per server the suite needs, each
  `command` + `url` + `reuseExistingServer`; skipped entirely when an external
  `PLAYWRIGHT_BASE_URL` is provided.
- **Project-dependency setup** — a `setup` project (auth/login) that other
  projects `dependencies` on, instead of duplicated per-spec login code.
- **CI-aware retries** — `retries: process.env.CI ? 2 : 0` and a CI reporter
  (`list` + `html`), so local runs stay fast and CI gets flake tolerance and an
  artifact report.

This repo's own `playwright.config.ts` implements all of the above natively
(`baseURL` at line 8, `webServer` at lines 89-96, CI retries at line 81).

### 1.5 The fixture layer — never import raw `@playwright/test`

All specs should import their primitives from one generic fixture module, e.g.:

```ts
// fixtures/index.ts
import { test as base, expect } from "@playwright/test";

export const test = base.extend<{ auth: AuthState }>({
  auth: async ({ request }, use) => {
    // ...login/session setup...
    await use(session);
  },
});

export { expect };
```

Every spec then does `import { test, expect } from "../fixtures"` — so when a
new capability (auth, seeded data, a mocked payment) is needed, it is added in
one place and every spec gets it. The strongest full example of this pattern is
**tomodakengo/playwright-fixture**; **GoogleChrome/webstatus.dev** is the best
single-source example (Nix dev environment + a Docker browser server connected
via `PW_TEST_CONNECT_WS_ENDPOINT`).

### 1.6 Verifying a new project assembled the five files

```bash
# same pinned image CI uses
docker compose run --rm e2e npx playwright test --project=chromium-smoke
# and from the Nix shell
nix develop --command bun run test:e2e -- --project=chromium-smoke
```

If both pass without touching the host's browser install, the contract is
complete.

---

## 2. Railway cron runbook (env-free specs only)

This runbook runs a **smoke subset** of the suite against a **deployed
production app** on a schedule. Because it targets the deployed app, it is
scoped to **env-free specs** — the three specs below make no network
assumptions and need no harness environment. **Do not run harness-gated specs
against a production app**: `dashboard-redesign-homepage`, `admin-mobile-compliance`,
`contractor-payout-onboarding-return`, and `delete-account` all require the app
deployment to carry harness env vars (`*_HARNESS_ENABLED=1` + keys) that
disable real payment/auth flows. Pointing them at a production domain without
that harness env will fail at best and exercise live Stripe/auth paths at
worst. Those specs run where the harness env exists — the compose runner and
CI, which boot the standalone server with the harness env injected by
`playwright.config.ts` (lines 24-36).

### 2.1 Create the service (Railway dashboard)

1. Open your project in the Railway dashboard.
2. **Create → GitHub Repo** and select this repository, then create a **second
   service** from it (the existing `web` service deploys the app; this new
   service runs only the cron job). Give it a name like `e2e-cron`.
3. Leave the service's deploy settings as-is — Railway builds from the repo.
4. In **Deploy Settings → Cron**, set a schedule (the Playwright docs and
   Railway's own cron support recommend a few times a day, e.g. every 6 hours:
   `0 */6 * * *`).

### 2.2 Configure variables

Add these to the `e2e-cron` service in **Variables**:

| Variable                   | Value                                                         |
| -------------------------- | ------------------------------------------------------------- |
| `RAILWAY_SHM_SIZE_BYTES`   | `268435456`                                                   |
| `PLAYWRIGHT_BROWSERS_PATH` | `/ms-playwright`                                              |
| `PLAYWRIGHT_BASE_URL`      | `https://<your-app>.up.railway.app` (the deployed app domain) |

`RAILWAY_SHM_SIZE_BYTES=268435456` raises the 64 MB default `/dev/shm` that
Chromium hits inside Railway's container. `PLAYWRIGHT_BROWSERS_PATH` points at
the prebaked browsers (the Railway image already ships them — no `install`
step). `PLAYWRIGHT_BASE_URL` makes the config skip its `webServer` entirely
(playwright.config.ts:7-9), so the cron job targets the deployed app instead of
trying to boot one.

### 2.3 Start command

In **Deploy Settings → Start Command**:

```bash
bun install --frozen-lockfile && bun run test:e2e -- tests/e2e/public-smoke.spec.ts tests/e2e/onboarding-smoke.spec.ts tests/e2e/accessibility-smoke.spec.ts --project=chromium-smoke --workers=1
```

Breaking it down:

- `-- tests/e2e/public-smoke.spec.ts tests/e2e/onboarding-smoke.spec.ts tests/e2e/accessibility-smoke.spec.ts` — the **scoped, env-free spec list** (public landing, onboarding, accessibility smoke).
- `--project=chromium-smoke` — chromium only; WebKit is not needed for a deployed-app smoke.
- `--workers=1` — one worker keeps memory and PID usage bounded inside Railway's container (see the PID ceiling note below).

### 2.4 The "process must exit" cron rule

Railway cron services are skipped when the previous run is still running — if
the job doesn't exit before the next scheduled tick, the run is dropped. Keep
the job short and self-terminating: `bun run test:e2e` exits with 0/1 when done,
and the smoke subset plus `--workers=1` keeps runtime small. Verify runs are
finishing in the **Deployments → Logs** tab.

### 2.5 Capacity notes

- Railway's shared CPU/memory cgroup has a ceiling of roughly **~1000 PIDs**;
  each Chromium renderer is a process, so keep concurrency low (`--workers=1`)
  and the spec list short.
- If the cron image is the official Playwright image, browsers are prebaked at
  `/ms-playwright` — do not add any `playwright install` step to the start
  command.

---

## 3. Bare-metal systemd runbook

Run the suite on a server (e.g. an Ubuntu 24.04 VPS) under systemd, hardened
but **Chromium-safe**. The unit runs as a non-root user with the filesystem
mostly read-only; Playwright's own docs warn that naive hardening breaks
Chromium — the two traps are `MemoryDenyWriteExecute` and AppArmor's
unprivileged-userns restriction.

### 3.1 systemd unit

`/etc/systemd/system/ignition-e2e.service`:

```ini
[Unit]
Description=Fox in the Truck Playwright e2e smoke (chromium)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=playwright
Group=playwright
WorkingDirectory=/srv/ignition

# --- Chromium-safe hardening -----------------------------------------
ProtectSystem=strict
ReadWritePaths=/srv/ignition/test-results /srv/ignition/playwright-report
PrivateTmp=yes
NoNewPrivileges=yes
ProtectHome=read-only
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
LockPersonality=yes
MemoryMax=2G
CPUQuota=80%
TasksMax=256

# NEVER set MemoryDenyWriteExecute=yes — it breaks the V8/Node JIT that
# Chromium and the test runner both require; every browser run dies with
# a SIGILL/exec-memory fault the moment JIT kicks in.

[Install]
WantedBy=multi-user.target
```

Notes:

- **`MemoryDenyWriteExecute=yes` is forbidden.** It blocks `mprotect(PROT_EXEC)`
  and Chromium's V8 JIT dies instantly. This is the single most common
  "hardened unit crashes Playwright" cause. Do not add it.
- `User=playwright` — non-root, matching the container's `pwuser` philosophy.
  Create it with `useradd --system --create-home playwright`.
- `ProtectHome=read-only` (not `yes`) — `yes` hides `/root`, but the Playwright
  browser cache can live under the service user's home; read-only keeps the
  browsers readable while blocking writes outside the two allowed dirs.
- `ProtectSystem=strict` + `ReadWritePaths` for `test-results/` and
  `playwright-report/` (the config writes both).
- `PrivateTmp=yes`, `NoNewPrivileges=yes`, `MemoryMax=2G`, `CPUQuota=80%`,
  `TasksMax=256` keep a runaway run from harming the host. `TasksMax` is a
  sane stand-in for Railway's PID ceiling on bare metal.

Enable it for a scheduled smoke:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now ignition-e2e.timer   # see timer below
sudo systemctl start ignition-e2e.service        # or run once by hand
```

And `/etc/systemd/system/ignition-e2e.timer`:

```ini
[Unit]
Description=Run e2e smoke every 6 hours

[Timer]
OnCalendar=*-*-* 0/6:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

`Type=oneshot` + `Restart=on-failure` (or the timer) matches the Railway cron
model: run, exit, and the next tick only fires if the previous run finished.

### 3.2 Ubuntu 24.04 AppArmor user-namespace handling

Ubuntu 23.10+/24.04 ships an AppArmor restriction on **unprivileged user
namespaces**. Chromium's sandbox needs `clone(CLONE_NEWUSER)`, so without a fix
every launch fails with:

```
Failed to launch the browser process! ... No usable sandbox!
```

Two documented fixes:

1. **sysctl (simplest, host-wide)** — `/etc/sysctl.d/90-apparmor-userns.conf`:

   ```ini
   kernel.apparmor_restrict_unprivileged_userns=0
   ```

   Apply with `sudo sysctl --system`.

2. **AppArmor profile with a `userns,` rule** — keep the host-wide restriction
   but let the e2e user create user namespaces. Add a profile at
   `/etc/apparmor.d/local/playwright` containing a `userns,` rule, then reload:
   `sudo systemctl reload apparmor`.

Use the sysctl route on a dedicated test box; use the profile route when the
host policy matters. (Inside the pinned Docker image and on Railway this is a
non-issue — the container has no AppArmor profile applied.)

---

## 4. CachyOS / Arch Linux notes

Arch-family hosts are the awkward corner: Playwright's `--with-deps` assumes
Debian.

- **`npx playwright install --with-deps` is unsupported.** The dependency
  resolver (`nativeDeps.ts`) has no Arch package mapping, so it shells out to
  `apt-get`, which does not exist on Arch → exit 127. Never rely on it on
  CachyOS/Arch.
- **Install the OS deps manually with pacman:**

  ```bash
  sudo pacman -S --needed nss nspr at-spi2-core libcups libdrm dbus libxcb \
    libxkbcommon libx11 libxcomposite libxdamage libxext libxfixes libxrandr \
    mesa pango cairo alsa-lib xorg-server-xvfb
  ```

- **Best native route: system Chromium from `cachyos-extra-v3`.** Rather than
  downloading Playwright's own Chromium, point the runner at the distro
  browser via `executablePath` in the config (per-machine override):

  ```ts
  use: {
    ...devices["Desktop Chrome"],
    executablePath: "/usr/bin/chromium",   // system chromium from cachyos-extra-v3
  },
  ```

  This keeps updates rolling with the distro and avoids a second 150 MB
  download. Keep this as a local/devshell override — do not bake it into the
  repo's committed `playwright.config.ts`.

- **`cachyos-ksm-settings` freeze bug.** The CachyOS KSM package can leave
  Chromium/Electron processes in a frozen state (kernel bugzilla 220599). If
  the browser hangs at launch, disable it with `systemctl disable --now
cachyos-ksm-settings` and retest before debugging anything else.
- **Rootless podman on btrfs.** CachyOS defaults to btrfs; rootless podman's
  default `overlay` storage driver errors with `'overlay' is not supported over
btrfs`. Fix in `~/.config/containers/storage.conf`:

  ```ini
  [storage]
  driver = "btrfs"
  ```

  Then the container route (`docker compose` / `podman compose`) works normally
  on btrfs hosts.

- **Nix route alternative**: this repo's `flake.nix` devshell is the
  zero-pacman option on CachyOS — `nix develop` provides Bun + Node + the exact
  Playwright 1.62.1 browsers via `PLAYWRIGHT_BROWSERS_PATH`, no distro packages
  beyond Nix itself.

---

## 5. Quick reference

```bash
# Local (chromium only)
bun install --frozen-lockfile && bun run test:e2e

# Container (chromium + webkit; same pinned image CI uses)
docker compose run --rm e2e bun run test:e2e

# Nix devshell (chromium + webkit)
nix develop --command bun run test:e2e

# CI-equivalent container commands (what .github/workflows/e2e.yml runs)
docker run --rm --user 1001 -v "$PWD":/work -w /work \
  -e PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
  mcr.microsoft.com/playwright:v1.62.1-noble \
  bash -lc "curl -fsSL https://bun.sh/install | bash -s -- bun-v1.3.11 && bun install --frozen-lockfile && bun run test:e2e"

# Railway cron (deployed-app smoke, env-free specs only) — see §2.3
```

Browsers, Bun, and Node are pinned in lockstep across the Docker image
(`v1.62.1-noble` + Bun 1.3.11), the workflow container block, the devcontainer,
and the Nix flake (`590d737e`) — so the same suite runs byte-for-byte identical
browser binaries on a laptop, a container, CI, Railway, and bare metal.
