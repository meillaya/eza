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
| Version | 0.4.0.0 |
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
| M2 Client architecture | complete | `web-logic` owns the whole native client state and update: Model/Action, pure `Update` monad + dispatcher over 13 per-group reducers, native `Effect` vocabulary, `Requests`/`Transport` API surface; `web` is a ~25-line adapter + Interpreter + views (`Eza.Web.Api`, the 13 Update modules, `Update.hs-boot`, facade and `-fno-specialise` are gone). 134 logic tests; wasm 7,705,966 raw / 2,218,780 gzip — under hard ceilings (7.8M/2.25M), raw target missed by 5,966 B and gzip by 18.8 KB; recorded as a dedicated size pass in M7 (no further architecture lever) |
| M3 Build/assets/runtime | complete | M3-A: content-addressed bundle + manifest + server `Eza.Assets`/`Eza.Shell`. M3-B: WASM built inside Nix from pinned FOD tarballs + vendored cabal revisions + a deterministic local Hackage index; `nix build .#eza-web` (7,775,380 raw / 2,201,325 gzip), `.#docker`, module check and docker smoke green; SRI pin/release-asset chain deleted; gates enforced in the Nix path |
| M4 Server architecture | complete | M4-C read-path auth + `Eza.Library`; M4-A dispatch from `Eza.Routes`; M4-B one `Eza.Problem` error path + catch-all JSON 500/503; M4-D async egress: schema v18 job columns, four 202 job routes (`snapshot`, `check-dead`, `ai/suggestions` tag-bucket, `webhooks/{id}/test`), `GET /api/v1/jobs/{id}` own-library only, per-library `Eza.Egress` worker (claimKind, cancel, bounded retry, restart requeue), handlers enqueue-only; snapshot file READ stays; 370 server examples/JobsSpec. |
| M5 Data layer/journal/upgrade | complete | M5-A checksummed `Eza.Migrate` engine (`schema_meta`, user v16/control v2). M5-B journal: user v17 adds `journal`/`journal_rows`, drops the undo tables/legacy JSON undo, captures before-images for bookmarks/tag links/highlights/links/captures/dead overrides, restores newest-first with URL-conflict refusal + FTS rebuild; Undo API unchanged. M5-C removed the 0.3 compatibility branches: no flat `EZA_DB` adoption (diagnosis-only hint), no unprefixed tokens, retired passkey sign-in routes removed (JSON 404; passkeys stay the second factor), flat backup stamps/flat layouts refused. One-way upgrade documented in docs/upgrade.md; 368 server examples. |
| M6 Feature completion, formal specs, deployment subtraction | complete | M6-DS removed Kubernetes/rclone/Tailscale; M6-formal added Jobs/Undo TLA+ models; M4-D completed the async spine (snapshot/dead-check/AI/webhook-test as durable jobs with client polling); the last feature TODO (graph label mode from the active saved view) is fixed with `ViewSpec` (158 logic tests); the client feature audit confirmed every shipped surface is wired and routed the remaining polish items (webhook-test failure visibility, AI status error, snapshot-404 state, busy guards, dead actions) into task-30. |
| M7 Validation/release | complete | Model-partition size program recovered the bundle to 5,313,531 raw / 1,714,657 gzip and restored the 7,800,000/2,250,000 ceilings (M4-D exception closed). Real-artifact upgrade drill PASS (old image 0.2.0.0 -> 0.4.0.0, control v2/library v18, data/session/async job survive, old binary refuses newer schema, rollback via old restore). Release blocker (hardcoded version, image PATH) found and fixed, re-drilled PASS. Version 0.4.0.0 in all sources with `scripts/version.sh` checking `Eza/Version.hs`; release notes, upgrade guide and release checklist complete; tag `v0.4.0.0` created in-repo. Pushing the tag/releasing the image remains an operator step (credentials/remote). |

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
2026-11-14 M2-B1: cabal test eza-web-logic       -> ok, 68 examples (Effect/Ledger, debounce, staleness, purity)
2026-11-14 M2-B1: bash scripts/build-web.sh      -> ok, 7,775,360 raw / 2,197,921 gzip; bundle bdf3fd91295305b6
2026-11-14 M4-C: cabal test eza-test             -> ok, 336 examples, 0 failures, 1 pending (LibrarySpec: read-path GET during BEGIN IMMEDIATE, throttled activity, balanced library cycles)
2026-11-14 M2-B1+M4-C: cabal test all            -> ok, 68 logic + 35 core + 336 server examples
2026-11-14 M2-B1+M4-C: fourmolu/hlint/check-docs/check-specs -> ok
2026-11-14 M2-B1+M4-C: bash scripts/e2e.sh       -> ok, 27 scripts passed, 0 failed
2026-11-14 M3-B: nix build .#eza-web            -> ok, 7,775,380 raw / 2,201,325 gzip (max 2,250,000), build 179bd4730093f782, manifest schema 1
2026-11-14 M3-B: nix build .#docker             -> ok, image /nix/store/b9xh97nzw807vzhb1rcfc8x7mh4g26pk-eza.tar.gz
2026-11-14 M3-B: checks.eza-module + version/check-docs/check-notices -> ok
2026-11-14 M3-B: docker-smoke (host network)    -> ok, eza:0.2.0.0 on 8080; Nix-built bundle HTTP smoke ok (sw ETag=build id, hashed CSS/WASM 200)
2026-11-14 M3-B: bash scripts/build-web.sh      -> ok, 7,775,360 raw / 2,197,921 gzip (max 2,250,000), build bdf3fd91295305b6
2026-11-14 M3-B: cabal test all                 -> ok, 68 logic + 35 core + 336 server examples, 0 failures, 1 pending
2026-11-14 M3-B: bash scripts/e2e.sh            -> ok, 27 scripts passed, 0 failed
2026-11-14 M3-B: fourmolu/hlint/version/check-docs/check-notices -> ok
2026-11-14 M4-A: cabal build all                -> ok; server lib 0 GHC warnings
2026-11-14 M4-A: cabal test eza-test            -> ok, 341 examples, 0 failures, 1 pending (336 + 5 DispatchSpec)
2026-11-14 M4-A: Server.hs                       -> 3,595 -> 469 lines; 12 Eza.Api.* modules; JSON 405/404
2026-11-14 M2-B2a: cabal test eza-web-logic      -> ok, 89 examples (68 + 21 HelperSpec)
2026-11-14 M2-B2a: bash scripts/build-web.sh     -> ok, 7,762,124 raw / 2,230,125 gzip, bundle 288c009c8777b95b
2026-11-14 M2-B2a: Update.hs                     -> 4,355 -> 437-line dispatcher over 13 group modules; 53 write requests adopted; 0 `/api/` literals in web
2026-11-14 M4-A+M2-B2a: fourmolu/hlint/check-docs/check-specs/version -> ok
2026-11-14 M4-A+M2-B2a: bash scripts/e2e.sh       -> 27/27; first full run flaked only `graph-views-smoke` (ledger-view navigation stayed on /graph), the script passes in isolation and the full rerun is green. Known flake to stabilise in M6/M7; the client ViewOpen flow was not changed after the isolated pass.
2026-11-14 M4-A+M2-B2a: nix build .#eza-web       -> ok, 7,763,006 raw / 2,221,493 gzip (max 2,250,000), manifest 5950f92afcf6fb3e
2026-11-14 M4-A+M2-B2a: nix build .#docker + checks.eza-module -> ok
2026-11-14 M4-B: cabal test eza-test            -> ok, 351 examples (+10 ProblemSpec: six toProblem converters, 404/405 JSON, catch-all 500/503)
2026-11-14 M5-A: cabal test eza-test            -> ok, 359 examples (+8 MigrationSpec: schema_meta v16/control v2, legacy backfill, tamper/rollback/upgrade)
2026-11-14 M2-B2b-1: cabal test eza-web-logic   -> ok, 106 examples (+17 ModelSpec)
2026-11-14 M2-B2b-1: bash scripts/build-web.sh  -> ok, 7,776,200 raw / 2,206,619 gzip (max 7,800,000 / 2,250,000; stopgap -fno-specialise in web)
2026-11-14 M6-DS: deployment subtraction         -> k8s/rclone/offsite/tailscale references removed; nix module check green; deployment figure removed
2026-11-14 round-4 gate: cabal test all         -> 106 logic + 35 core + 359 server examples, 0 failures, 1 pending
2026-11-14 round-4 gate: bash scripts/e2e.sh    -> ok, 27 scripts passed, 0 failed
2026-11-14 round-4 gate: bash scripts/build-web.sh -> ok, 7,776,200 raw / 2,206,619 gzip, bundle bb04b64055cb29a8
2026-11-14 round-4 gate: fourmolu/hlint/check-docs/check-specs/version/notices -> ok
2026-11-14 round-4 gate: nix build .#checks.eza-module + .#docker -> ok (after staging the new Migrate.hs for the git flake)
2026-11-14 M6-formal: bash scripts/check-specs.sh -> ok (MultiUser 48,290 / Extensions 231,777 / Jobs 2,058 / Undo 215,683 distinct states; JSON fixtures pass)
2026-11-14 M5-B: cabal test eza-test            -> ok, 362 examples, 0 failures, 1 pending (+ JournalSpec; v16->v17 backup, table-by-table undo identity, prune 100, newer-schema refusal)
2026-11-14 M5-B: verify CLI                    -> schema ok (v17/v17); no undo_* tables; journal empty on a fresh install
2026-11-14 M2-B2b-2: cabal test eza-web-logic   -> ok, 134 examples (+28 UpdateSpec across all route groups)
2026-11-14 M2-B2b-2: bash scripts/build-web.sh  -> ok, 7,705,966 raw / 2,218,780 gzip, bundle bb6a997a424f2fa3; -fno-specialise removed
2026-11-14 round-5 gate: cabal build all --ghc-options=-Werror -> ok (0 warnings); cabal test all -> 134 logic + 35 core + 362 server examples
2026-11-14 M4-D: cabal test all                  -> ok, 151 logic + 35 core + 370 server examples (+8 JobsSpec; migration v18, dedupe/claim/cancel/crash/retry, enqueue-only HTTP, cross-account 404, no-inline-egress source check)
2026-11-14 M4-D: cabal build all -Werror        -> ok (0 warnings; three unused-import/local-bind warnings in the client test slice fixed)
2026-11-14 M4-D: bash scripts/build-web.sh      -> 7,937,977 raw / 2,285,814 gzip under the RECORDED TEMPORARY ceilings 8,000,000/2,300,000; bundle 4f032781c43525e3
2026-11-14 M4-D: bash scripts/e2e.sh            -> ok, 27/27 scripts (async job polling in deeplink/flows/undo)
2026-11-14 round-6 gate: fourmolu/hlint/check-docs/check-specs/version/notices -> ok
2026-11-14 M5-C: cabal test all                  -> ok, 158 logic + 35 core + 368 server examples; -Werror 0 warnings
2026-11-14 M5-C: bash scripts/build-web.sh       -> ok, 7,938,321 raw / 2,285,188 gzip, bundle d6204524293296bc
2026-11-14 M5-C: check-docs/version/notices/spec/fourmolu/hlint -> ok
2026-11-14 round-7 e2e: bash scripts/e2e.sh      -> ok, 27/27 scripts (no legacy passkey login; graph label mode unchanged at route level)
2026-11-14 M7 size program (task-29): build-web  -> ok, 5,313,531 raw / 1,714,657 gzip (targets <7.7M/<2.2M met); ceilings restored to 7,800,000/2,250,000
2026-11-14 M7 release blocker: version/PATH fix  -> `eza-bookmarks version` = 0.4.0.0; boot/health version; image PATH; version.sh checks Eza/Version.hs
2026-11-14 M7 upgrade drill (fixed image)        -> PASS all steps (old 0.2.0.0 -> 0.4.0.0 control v2/library v18, async job done, old binary refuses newer schema, rollback via old restore with documented chown)
2026-11-14 round-8 gates: build/test/build-web/e2e/lint/docs/spec/version/notices -> ok (158 logic + 35 core + 368 server; e2e 27/27; wasm 5,313,531/1,714,657)
2026-11-14 M7 release: release image               -> 0.4.0.0 built from the tagged tree; version/PATH/health/verify/setup smoke green
2026-11-14 M7 release: tag v0.4.0.0                 -> created in-repo (annotated); push/publish remains an operator step
```

## Round-4 note

M2-B2b part 1 was committed by its owner as `664d6ea` (Model/Action moved
into `web-logic`). The Lead follow-up commit drops two unused imports that the
committed tree still had; the facade/stopgap and remaining task-21 work are
recorded above.

## M2-B1 / M4-C decisions (recorded)

- M2-B1 was a **strangler slice**: `LedgerState`/`updateLedger` and the
  Miso-free `Effect` ADT live in `web-logic`; the Miso `Model` stayed the single
  store behind a projection. M2-B2a replaced the projection with one
  `Eza.Web.Interpreter` and split the update reducer; M2-B2b moves the whole
  `Model`/`Action` into `web-logic` with `Text`, which is the remaining native
  test seam and the bundle-size recovery lever.
- M2-B2a: `Update.hs` is a compiler-enforced 406-arm dispatcher (437 lines) over
  13 group modules; `Update.hs-boot` breaks the recursive dispatch cycle and is
  a tracked source file. `Eza.Web.Interpreter` is the only web module that runs
  browser FFI/Miso effects. Seven epoch counters became typed `RequestId`
  streams; documented Int survivors are timeout handles/frame phases/counts, not
  staleness. All 53 write `ClientRequest`s are adopted and the native `ApiSpec`
  pins every method/path; zero `/api/` literals remain in `web/src`.
- M2-B2a bundle: 7,762,124 raw (−13,236 vs M2-B1) / 2,230,125 gzip
  (+32,204). The raw < 7,700,000 target is still unmet; module boundaries cost
  gzip even as raw went down, so M2-B2b must recover headroom before more client
  code lands. No ceilings were raised in this slice.
- Auth is read-only: sessions/tokens validate on the read pool; activity
  (`last_seen_at`/`last_used_at`) is a throttled (60 s) writer touch only when
  stale. A normal GET takes no writer. The test-only `enableWorkers` global is
  gone; the supervisor is the only worker starter.
- `Eza.Library` owns the writer, read pool, layout cache and worker handles;
  worker connections are bracketed and close on cancel. `Db.connectionStats`
  exists for leak tests (one MVar bump per open/close).
- **Bundle size is tight:** 7,775,360 raw (24,640 under the 7.8 MB guard) and
  2,197,921 gzip in the devenv build. The Nix release build uses the NixOS gzip,
  which compresses the same bytes to 2,201,334, so the gzip hard max was raised
  from 2,200,000 to 2,250,000 in M2-B1/M3-B (target stays 1.7 MB). The Nix
  derivation must not override the size gates; M2-B2 must recover headroom
  before any further client growth, and do not raise the ceilings again without
  recording the reason here.

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

## M3-B decisions (recorded)

- The WebAssembly client is built by Nix from source (`nix/eza-web.nix`): the
  `ghc-wasm-meta` input is locked to the same revision as devenv, Hackage
  releases are 56 fixed-output fetchurls (`nix/wasm-hackage.nix`), their solver
  metadata is vendored under `nix/wasm-cabal/`, and `nix/build-wasm-index.py`
  writes the deterministic local Hackage index. A dependency-store derivation is
  keyed only on the wasm plan; a source change re-links and re-bundles.
  `scripts/update-wasm-deps.sh` refreshes the freeze file, FODs and vendored
  cabal revisions together.
- The Nix derivation runs the unchanged `scripts/build-web.sh`/`bundle-web.sh`
  and **must not override the size gates**; the same gates reject the release
  build. A ~20-byte content delta between the Nix and devenv wasm remains (gzip
  2,201,325 vs 2,197,921), so the gzip hard max is 2,250,000; the 1.7 MB target
  is still unmet and M2-B2 must recover headroom.
- The release chain is now image-only: `release.yml` creates the GitHub release,
  `release-image.yml` builds `.#docker`; `nix/web-assets.json`,
  `scripts/release-asset.sh`, `eza-web-pin` and all SRI pin logic are deleted.
- `docker-smoke.sh` validates the content-addressed loader/WASM/CSS from the
  generated SW (not the old fixed `/assets/app/*` paths). In this sandbox it ran
  with `EZA_DOCKER_NETWORK=host` because the local Docker bridge/netavark config
  is broken; CI uses the normal bridge.
- CI cold `.#eza-web`/`.#docker` builds are long without a binary cache. Follow-up
  (M6/M7): push/cache the wasm-deps derivation (Cachix) or run the Nix wasm build
  nightly so the 120-minute docker-smoke job stays reliable.

## M4-A decisions (recorded)

- Dispatch parses each request once with `Routes.matchRoute` and cases on the
  `Route` ADT; the handler families live in `Eza.Api.*` (Common/Context are
  internal modules that break the Server↔handler import cycle). No bare
  method+path literals remain in dispatch.
- Unknown `/api` paths now return JSON 404 before the guard (previously
  401/403); a known path with an unsupported method returns JSON 405 with an
  `Allow` header computed from Routes. HEAD on token read routes runs the GET
  handler; OPTIONS on the public surface is derived from Routes instead of the
  old hand-written allow list.
- `Update.hs-boot` is used to break the recursive dispatch cycle in the client
  update groups; it is a tracked source file, not a build product.

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

- M3-B resolved the release blocker: the deployment flake now builds and
  packages a bundle with `asset-manifest.json`; there is no manifest-less path.
- Remaining target removals (M6): Kubernetes manifests/docs, rclone offsite
  backup (server + NixOS module + image), Tailscale Serve (module + docs).
  Kept: Docker, Compose, NixOS module, Caddy.
- One-way compatibility cut happens in M5 as part of schema v17 and the
  legacy-library relocation; the upgrade guide lands in M7.

## M4-B / M5-A / M2-B2b-1 / M6-DS decisions (recorded)

- M4-B: `catchAllMiddleware` sits inside `app` (so security/gzip/access logging
  stay outside and TestHarness exercises it). Async exceptions are rethrown for
  worker cancellation; SQLite busy/locked becomes 503 `database_busy`; the log
  line uses the `Eza.Routes` template, so a share token never appears. All six
  feature error ADTs now have exactly one `toProblem`.
- M5-A: shipped migrations are now frozen twice over: editing or renaming any
  v1..v16 (or control v1..v2) migration breaks checksum verification on every
  existing DB. A newer schema is refused by older binaries; rollback means
  restoring the pre-migration backup (user DBs) or the pre-upgrade stamp
  (control DB, which still has no automatic pre-migration copy). `verify`
  without `--user` opens pending account DBs and may migrate them as a side
  effect — documented in the CLI help.
- M2-B2b part 1: converting all views to native `Text` accessors measured
  7,956,845 raw, so the facade (64 `MisoString` accessors + `Render.Event`) was
  kept and `-fno-specialise` added to web as a documented stopgap. It must be
  removed once the reducers move and the facade is deleted; sizes remain under
  the hard ceilings but not at the targets.
- M6-DS: the deployment Excalidraw figure was deleted rather than regenerated
  (its content was the three old targets); the README/architecture now describe
  Docker/Compose, NixOS+Caddy only. `Fetch.hs` keeps a factual CGNAT comment
  that mentions overlay networks, not the removed deployment branch.

## Round-5 decisions (recorded)

- **Journal engine (M5-B):** one append-only `journal` + `journal_rows` table
  replaces eight per-feature undo tables and the legacy JSON undo payload.
  Before-images are JSON per row inside the caller's transaction and the
  journal is pruned to the newest 100 changes. The public `Eza.Undo` API and
  wire DTOs are unchanged, so call sites did not move; only legacy-only
  helpers were deleted. The upgrade is one-way: old undo history is not
  migrated, older binaries refuse schema v17, rollback is the pre-migration
  backup. `spec/Undo.tla` models the restore/conflict rule.
- **Client completion (M2-B2b):** the Miso shell is reduced to adapter +
  interpreter + views; native reducers own all 407 actions and the model.
  The raw size target (<7.7M) is missed by 5,966 B and gzip (<2.2M) by
  18.8 KB with no ceiling changes; a dedicated size pass (view/renderer
  dedup, wasm flags) is recorded for M7, not more architecture.
- **Formal scope:** `Jobs.tla`/`Undo.tla` are bounded design checks; worker
  timing, network failure timing and refinement are explicitly out of scope.
  TLC deadlock checking is disabled for the two new models because they model
  batch processes that quiesce; safety invariants still run to exhaustion.
- **Pending:** M4-D (async egress, schema v18), M5-C compatibility cleanup,
  M6 feature completion, M7 upgrade drill/release.

## Round-6 decisions (recorded)

- **Async egress contract (M4-D):** handlers only validate and enqueue a
  `jobs` row in the write transaction and return 202 `{"job_id": n}`; the
  per-library `Eza.Egress` worker performs all network/subprocess work. One
  active job per (kind, target) is a partial unique index (dedupe returns the
  existing id), retries are bounded, and a restart requeues running jobs. The
  four flows are snapshot capture, dead-link sweep, AI suggestions (existing
  tag/all bucket, `{"tag":Text}` or `{}`) and webhook test; `GET
  /api/v1/jobs/{id}` is own-library only and returns state/attempts/result/error.
  The snapshot file READ stays a normal GET; only capture became a job.
- **WASM ceiling exception (recorded, temporary):** the async job client grew
  the linked binary by ~232 KB (7,937,977 raw / 2,285,814 gzip) after a
  timeboxed trim pass failed to recover it (`-fno-specialise` worse, DCE no
  gain, generic containers not the main cost). Hard ceilings are temporarily
  raised to 8,000,000/2,300,000 in `scripts/build-web.sh` with a written
  reason. M7 must run the planned size pass (per-kind poll slots, typed result
  actions, no `Maybe Value` in Actions, codegen bisect), recover the
  <7.7M/<2.2M targets, and lower the ceilings back to 7,800,000/2,250,000.
- **Snapshot viewer:** `GET /api/v1/bookmarks/{id}/snapshot` remains the
  read-only file route used by the viewer; `POST` is the capture job.

## Round-7 decisions (recorded)

- **WASM size target not reachable by trimming (M7 investigation).** Measured:
  pre-M4-D baseline 7,706,279 raw / 2,218,780 gzip (already above both targets),
  M4-D 7,937,977/2,285,814; fixed per-kind poll slots + typed results
  7,973,858 raw/2,276,041 gzip; no-polling bisect 7,823,461 raw (polling
  ~115 KB, other M4-D ~117 KB); Model-width probe ~12 KB raw per extra field
  (261-field flat record, so a +2.3% width already costs ~71 KB). Flags were
  neutral or worse. The recorded 8,000,000/2,300,000 exception therefore stands
  until the Model-partition program (task-29) runs; that program is the only
  measured lever and must land before the ceilings return to 7,800,000/2,250,000.
- **0.3 compatibility removal (M5-C):** 0.4 opens only the control DB + per-account
  libraries, accepts only prefixed tokens, serves only the current passkey
  second-factor routes and accepts only stamp-directory backups. The upgrade
  path is backup + forward migration (docs/upgrade.md); old flat data/tokens/
  routes are refused with a diagnosis, not a fallback.

## Round-8 decisions (recorded)

- **WASM ceiling exception closed.** The Model-partition program split the
  flat 261-field record into 15 nested groups behind total INLINE selectors;
  the 462 record-update sites now copy ~15-25 fields instead of the whole
  record. Measured bundle: 5,313,531 raw / 1,714,657 gzip (from 7,938,321 /
  2,285,188), matching the measured ~12 KB/field copy cost. The hard ceilings
  are back to 7,800,000/2,250,000; the 1,700,000 gzip target stays the warning
  threshold (current bundle is 14.6 KB above it, a known remaining polish).
- **Release version is single-source and checked.** `server/src/Eza/Version.hs`
  holds the one literal used by `eza-bookmarks version`, the boot payload and
  `/healthz`; `scripts/version.sh` compares it with flake.nix and the Cabal
  versions. Pre-0.4 images printed a hardcoded 0.1.0 and lacked the server bin
  on PATH; both fixed and documented in docs/upgrade.md/docs/release.md.
- **Upgrade path is drilled, not assumed.** The local 0.2.0.0 image upgraded a
  real account/bookmark/backup to control v2/library v18, kept sessions and the
  async job path working, refused the old binary on the migrated schema, and
  restored the old installation from the pre-upgrade stamp.
