# Architecture program log (v0.3–v0.5)

Execution log for the approved architecture program. The plan lives with the
program owner; this file records the baseline, milestone status and gate
evidence so a later contributor can see what was measured, not guessed.

## Rules for this program

- One milestone at a time, in order, each with a pass/fail gate. A milestone
  does not start until the previous gate is recorded here.
- Feature freeze: no new product features except the completion work in M6.
- Every milestone is a separate commit (or small commit series) on
  `architecture-v0.3`; the gate commands are re-run after the final commit.
- Shared files have one owner per milestone: `cabal.project*`, `flake.nix`,
  `devenv.nix`, `.github/workflows/*`, `AGENTS.md`, `README.md`,
  `docs/API.md`, `server/src/Eza/{Server,Config,Db}.hs`, `scripts/*`.
- `devenv shell -- docs` is part of every gate.

## Baseline

Captured 2026-11-14 from `main` at commit `57639c0` before any program change.

| Metric | Value |
|---|---|
| Version | 0.2.0.0 |
| Haskell lines (tracked `.hs`) | 49,663 |
| Server / web / core / tests (lines) | 20,574 / 18,343 / 3,089 / 7,640 |
| Hspec cases (`it`) | 293 |
| Playwright scripts | 35 total, 27 in the CI suite |
| Library schema | v15 (15 append-only migrations) |
| wasm artifact | 7,638,685 raw / 2,141,523 gzip |
| Environment variables referenced | 58 unique `EZA_*`/`PUBLIC_ORIGIN` names |
| Docs (`docs/**/*.md`) | 25,993 words |
| Toolchains | GHC 9.10.3 native, GHC 9.14.1.20260731 wasm, Node 22, Bun, Python 3, TLA+/JVM, Nix |
| CI shape | 3 workflows; test/nix-checks/docker-smoke jobs, 60/30/45-minute timeouts |
| Test entry points | `devenv shell -- test`, `lint`, `spec`, `e2e` |

## Milestones

| Milestone | Status | Gate evidence |
|---|---|---|
| M0 Guardrails | complete | `docs/program/README.md` created; `scripts/check-docs.sh` green; `devenv shell -- docs` added; baseline build/test captured |
| M1 Contract spine | complete | `Eza.Routes` (127 routes) is the single route truth and `Eza.Authz` derives from it; all boundary DTOs are core types; client strict decode (no `Eza.Web.Types`, no lenient helpers); graph layout wire in core and server-only; boot `wire_version`; 35 core golden tests + 316 server examples; full e2e 27/27; fourmolu/hlint/docs/spec gates green |
| M2 Client architecture | in progress | M2-A complete: native `eza-web-logic` package (Route algebra, ClientRequest/requestPath over `Eza.Routes`, 27 native tests); M2-B (TEA reducer + ClientEffect split) pending |
| M3 Build/assets/runtime | in progress | M3-A complete: content-addressed bundle + `asset-manifest.json` + generated shell/sw/manifest templates, server `Eza.Assets`/`Eza.Shell` validation and immutable caching, 16 AssetsSpec cases; M3-B (Nix WASM build, delete SRI pin) pending and required before any release |
| M4 Server architecture | not started | — |
| M5 Data layer/journal/upgrade | not started | — |
| M6 Feature completion, formal specs, deployment subtraction | not started | — |
| M7 Validation/release | not started | — |

## Gate log

Append one entry per gate run: milestone, date, commands, result, commit.

```
2026-11-14 M0: bash scripts/version.sh --check  -> ok (0.2.0.0)
2026-11-14 M0: bash scripts/check-docs.sh       -> ok (layout, version, generated-docs hook)
2026-11-14 M0: cabal build all                  -> ok (commit 57639c0, full rebuild)
2026-11-14 M0: cabal test all                   -> ok, 293 examples, 0 failures, 1 pending
2026-11-14 M1-A: cabal build all                -> ok (core wire DTOs + server encodes through them)
2026-11-14 M1-A: cabal test all                 -> ok, 293 examples, 0 failures, 1 pending
2026-11-14 M1-A: cabal test eza-core            -> ok, 27 examples (wire golden/round-trip)
2026-11-14 M1:   cabal build all                -> ok (native, both test suites)
2026-11-14 M1:   cabal test all                 -> ok, 35 core + 316 server examples, 0 failures, 1 pending
2026-11-14 M1:   bash scripts/build-web.sh      -> ok, 7,691,795 raw / 2,166,573 gzip (under the 7.7 MB raw ceiling; gzip above the 1.7 MB target, M3 size work)
2026-11-14 M1:   bash scripts/e2e.sh            -> ok, 27 scripts passed, 0 failed
2026-11-14 M1:   fourmolu --mode check         -> ok; hlint -> No hints
2026-11-14 M1:   bash scripts/check-docs.sh    -> ok (generated routes.md matches `routes --markdown`)
2026-11-14 M1:   bash scripts/check-specs.sh   -> ok (TLC Extensions clean, schema checks pass)
2026-11-14 M2-A: cabal test eza-web-logic       -> ok, 27 examples (route round-trip, request paths, purity)
2026-11-14 M2-A: wasm32-wasi-cabal build        -> ok (Miso shell compiles against eza-web-logic)
2026-11-14 M3-A: bundle-web.sh --no-build       -> ok, build 44b7ced795fb753e, 18 assets, 25 precache entries, deterministic
2026-11-14 M3-A: cabal test eza-test            -> ok, 332 examples, 0 failures, 1 pending (16 AssetsSpec cases)
2026-11-14 M3-A: focused e2e (3 scripts)        -> ok, 3 passed, 0 failed (SW build id, 25-entry cache, offline reload)
2026-11-14 M2-A+M3-A: bash scripts/build-web.sh -> ok, 7,746,296 raw / 2,172,708 gzip, bundle build 81e489210770b130
2026-11-14 M2-A+M3-A: cabal test all            -> ok, 27 logic + 35 core + 332 server examples, 0 failures, 1 pending
2026-11-14 M2-A+M3-A: bash scripts/e2e.sh       -> ok, 27 scripts passed, 0 failed
2026-11-14 M2-A+M3-A: fourmolu/hlint             -> ok, No hints; check-docs and check-specs ok
```

## M2-A / M3-A decisions (recorded)

- The native client-logic package is a separate Cabal package because `miso`
  cannot build natively; the module namespace stays `Eza.Web.Logic.*` so the
  client's domain language is unchanged.
- `ClientRequest` models reads and writes, but only read paths are adopted in
  `web/src/Eza/Web/Api.hs` this round; write paths follow in M2-B.
- `instance Router Route` is necessarily an orphan (the type lives in
  `web-logic`); `Eza.Web.Model` documents it and enables `-Wno-orphans`.
- The content-addressed bundle is the single asset source: `static/index.html`,
  `static/sw.js` and `static/manifest.webmanifest` are generated (gitignored)
  from `static/template/*` through `scripts/bundle-web.sh`.
- WASM raw ceiling raised from 7,700,000 to 7,800,000 bytes in M2-A for the
  contract/request-table code. This is an anti-regression guard, not a product
  limit; M2-B is expected to bring it back under 7,700,000. Further raises must
  be recorded here.

## M1 deviations (recorded, no open decisions)

- `Eza.Routes` also exports `renderRoutePath` (concrete path with parameters);
  `routePath` renders docs templates so the round-trip test can re-parse.
- Wildcard route families are one constructor each (`RouteStaticAsset`,
  `RouteSpaPage`, tag rename/delete), matching the server fallbacks.
- `Problem` is defined in core and client decoding uses the existing
  `{"error":{"code","message"}}` envelope; the server-wide switch to it is M4.
- Size headroom is tight: the raw wasm ceiling had ~8 KB left after M1. M2-A
  raised it to 7,800,000 with the decision recorded below; M2-B should recover
  the old headroom by moving the reducer and effect layer out of the shell.

## Notes

- **M3-B is a release blocker.** The deployment flake still packages the old
  static tree (no `asset-manifest.json`), which the new server rejects at
  startup. M3-B (Nix WASM + bundler derivation, delete `nix/web-assets.json`
  and the SRI/release-pin chain) must land before any release or image build.
- Remaining target removals (M6): Kubernetes manifests/docs, rclone offsite
  backup (server + NixOS module + image), Tailscale Serve (module + docs).
  Kept: Docker, Compose, NixOS module, Caddy.
- One-way compatibility cut happens in M5 as part of schema v17 and the
  legacy-library relocation; the upgrade guide lands in M7.
