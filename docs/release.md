# Release checklist

This is the operator/contributor checklist for cutting an eza release. The
container image and the Nix outputs are the artifacts; both are built from the
same tagged revision. `scripts/version.sh` is the single version source and the
`v*` tag must equal `v$(scripts/version.sh)`.

## 1. Version bump

Update every copy of the version (the Cabal files, `flake.nix` and the
deployment examples that name an image tag), then check the copies agree:

```bash
grep -RIn --exclude-dir=.devenv --exclude-dir=dist-newstyle '0\.[0-9]\+\.[0-9]\+\.[0-9]\+' \
  core server web web-logic flake.nix docs README.md deploy .github
bash scripts/version.sh --check
```

Version sources: `core/eza-core.cabal`, `server/eza-server.cabal`,
`web/eza-web.cabal`, `web-logic/eza-web-logic.cabal`, `flake.nix`, and
`server/src/Eza/Version.hs` (the `eza-bookmarks version`, boot payload and
`/healthz` value; `scripts/version.sh` checks it too). The image
examples in `docs/deployment-docker.md`, `docs/upgrade.md`, `README.md` and
the Compose files name the current tag. `CHANGELOG.md` gets the release section
and the new version's schema map.

## 2. Pre-release gates

Run from the repository root inside the devenv shell:

```bash
devenv shell -- bash scripts/build-web.sh        # bundle + size ceilings
devenv shell -- cabal build all --ghc-options=-Werror
devenv shell -- cabal test all                   # core + web-logic + server
devenv shell -- bash scripts/e2e.sh              # 27 browser scripts
devenv shell -- bash scripts/check-specs.sh      # 4 TLC models + JSON schemas
devenv shell -- bash scripts/check-docs.sh
devenv shell -- bash scripts/check-notices.sh --plan
devenv shell -- bash scripts/version.sh --check
devenv shell -- bash -c 'fourmolu --mode check core server web web-logic && hlint core server web web-logic'
```

WASM size gate: the bundle must pass `scripts/build-web.sh` with its recorded
hard ceilings. The product target is `< 1,700,000 B` gzip; the hard ceilings
are the guard against an accidental debug/dependency build. Any ceiling change
needs a written reason in `scripts/build-web.sh` and
`docs/program/README.md`, plus a recovery plan. The M4-D exception
(8,000,000/2,300,000) must be reversed by the M7 size pass before release.

Nix gates:

```bash
nix build .#eza-web
nix build .#docker
nix build .#checks.x86_64-linux.eza-module
```

## 3. Upgrade drill (one-way)

The release claims a backup-first, one-way upgrade from the previous release.
Drill it with the released images, not only with unit tests:

1. Start the previous release image (`ghcr.io/meillaya/eza:<previous>`) on a
   scratch volume, claim an account, import a small Netscape file, create a
   tag, a view and a webhook, and run `eza-bookmarks backup`.
2. Copy the stamp off the volume. Start the release-candidate image on the
   same volume with the same `PUBLIC_ORIGIN`/`EZA_RP_ID`.
3. `docker exec ... eza-bookmarks version` must print the release tag (a
   pre-0.4 image may print an older/hardcoded version — record it, do not
   trust it as the migration check), and `docker exec ... eza-bookmarks verify`
   must pass; the account, bookmark, tag, view and webhook must be present; the
   undo history starts empty (documented); one async job
   (snapshot/dead-check/AI/webhook test) must finish through
   `GET /api/v1/jobs/{id}`. When copying a stamp with `docker cp` for the
   rollback step, `chown` it to the image user (10001) or the old restore fails
   its stamp integrity check.
4. Negative: the previous-release binary against the migrated volume must
   refuse it ("schema is newer than this binary"), and
   `eza-bookmarks restore <stamp> --yes` with the previous release must bring
   the old installation back.
5. If a step fails, fix it before tagging; the upgrade path is part of the
   release contract. `docker load` tags the local image as
   `localhost/eza:<version>`; `docker tag` it to the published name when the
   drill uses that name.

## 4. Tag and publish

```bash
git tag -a v<version> -m "eza <version>"
git push origin v<version>
```

Pushing the tag runs `.github/workflows/release.yml` (creates the GitHub
release from the tagged tree) and then `.github/workflows/release-image.yml`
(publishes the versioned container image and its Compose file). Do not
hand-publish an image that was not built from the tagged revision.

## 5. Post-release

- Pull the published image and repeat the first-run/setup/healthcheck smoke.
- Confirm `eza-bookmarks version` prints the tag in the image.
- Update the upgrade guide with the previous release's schema row.
- Record the release in `docs/program/README.md` and close the M7 row.
