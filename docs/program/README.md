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
| M2 Client architecture | not started | — |
| M3 Build/assets/runtime | not started | — |
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
```

## M1 deviations (recorded, no open decisions)

- `Eza.Routes` also exports `renderRoutePath` (concrete path with parameters);
  `routePath` renders docs templates so the round-trip test can re-parse.
- Wildcard route families are one constructor each (`RouteStaticAsset`,
  `RouteSpaPage`, tag rename/delete), matching the server fallbacks.
- `Problem` is defined in core and client decoding uses the existing
  `{"error":{"code","message"}}` envelope; the server-wide switch to it is M4.
- Size headroom is tight: the raw wasm ceiling has ~8 KB left. M3 must either
  shrink the bundle or raise the ceiling with a recorded decision before adding
  client code.

## Notes

- Remaining target removals (M6): Kubernetes manifests/docs, rclone offsite
  backup (server + NixOS module + image), Tailscale Serve (module + docs).
  Kept: Docker, Compose, NixOS module, Caddy.
- One-way compatibility cut happens in M5 as part of schema v17 and the
  legacy-library relocation; the upgrade guide lands in M7.
