# Third-party notices

eza itself is licensed under the Apache License 2.0 ([LICENSE](LICENSE)).
This file lists the third-party software, fonts, and other assets that are
distributed with, compiled into, or required at runtime by eza.

The server is a Haskell program; its dependency tree is resolved by Cabal. The
versions below are the ones in the development environment used for this
release. The client is written in Haskell with Miso and compiled to WebAssembly
with GHC's WebAssembly backend.

## Haskell libraries (server and client)

| Package | Version | License | Link |
|---|---|---|---|
| GHC (compiler and runtime) | 9.10.3 | BSD-3-Clause | <https://www.haskell.org/ghc/> |
| base | 4.20.2.0 | BSD-3-Clause | <https://hackage.haskell.org/package/base> |
| aeson | 2.3.2.0 | BSD-3-Clause | <https://hackage.haskell.org/package/aeson> |
| async | 2.2.6 | BSD-3-Clause | <https://hackage.haskell.org/package/async> |
| base16 | 2.0 | BSD-3-Clause | <https://hackage.haskell.org/package/base16> |
| base16-bytestring | 1.0.2.0 | BSD-3-Clause | <https://hackage.haskell.org/package/base16-bytestring> |
| base64-bytestring | 1.2.1.0 | BSD-3-Clause | <https://hackage.haskell.org/package/base64-bytestring> |
| bytestring | 0.12.2.0 | BSD-3-Clause | <https://hackage.haskell.org/package/bytestring> |
| containers | 0.7 | BSD-3-Clause | <https://hackage.haskell.org/package/containers> |
| cookie | 0.5.1 | MIT | <https://hackage.haskell.org/package/cookie> |
| crypton | 1.1.5 | BSD-3-Clause | <https://hackage.haskell.org/package/crypton> |
| crypton-asn1-encoding | 0.10.0 | BSD-3-Clause | <https://hackage.haskell.org/package/crypton-asn1-encoding> |
| crypton-asn1-parse | 0.10.0 | BSD-3-Clause | <https://hackage.haskell.org/package/crypton-asn1-parse> |
| crypton-asn1-types | 0.4.1 | BSD-3-Clause | <https://hackage.haskell.org/package/crypton-asn1-types> |
| crypton-connection | 0.4.6 | BSD-3-Clause | <https://hackage.haskell.org/package/crypton-connection> |
| crypton-pem | 0.3.0 | BSD-3-Clause | <https://hackage.haskell.org/package/crypton-pem> |
| crypton-socks | 0.6.2 | BSD-3-Clause | <https://hackage.haskell.org/package/crypton-socks> |
| crypton-x509 | 1.9.1 | BSD-3-Clause | <https://hackage.haskell.org/package/crypton-x509> |
| crypton-x509-store | 1.9.0 | BSD-3-Clause | <https://hackage.haskell.org/package/crypton-x509-store> |
| crypton-x509-system | 1.9.0 | BSD-3-Clause | <https://hackage.haskell.org/package/crypton-x509-system> |
| crypton-x509-validation | 1.9.1 | BSD-3-Clause | <https://hackage.haskell.org/package/crypton-x509-validation> |
| data-default | 0.8.0.2 | BSD-3-Clause | <https://hackage.haskell.org/package/data-default> |
| data-default-class | 0.2.0.0 | BSD-3-Clause | <https://hackage.haskell.org/package/data-default-class> |
| direct-sqlite | 2.3.29 | BSD-3-Clause | <https://hackage.haskell.org/package/direct-sqlite> |
| directory | 1.3.8.5 | BSD-3-Clause | <https://hackage.haskell.org/package/directory> |
| ech-config | 0.0.2 | BSD-3-Clause | <https://hackage.haskell.org/package/ech-config> |
| fast-logger | 3.2.9 | BSD-3-Clause | <https://hackage.haskell.org/package/fast-logger> |
| file-embed | 0.0.16.0 | BSD-2-Clause | <https://hackage.haskell.org/package/file-embed> |
| filepath | 1.5.4.0 | BSD-3-Clause | <https://hackage.haskell.org/package/filepath> |
| hpke | 0.2.0 | BSD-3-Clause | <https://hackage.haskell.org/package/hpke> |
| http-client | 0.7.19 | MIT | <https://hackage.haskell.org/package/http-client> |
| http-client-tls | 0.4.0 | MIT | <https://hackage.haskell.org/package/http-client-tls> |
| http-semantics | 0.4.2 | BSD-3-Clause | <https://hackage.haskell.org/package/http-semantics> |
| http-types | 0.12.6 | BSD-3-Clause | <https://hackage.haskell.org/package/http-types> |
| http2 | 5.4.13 | BSD-3-Clause | <https://hackage.haskell.org/package/http2> |
| jose | 0.13 | Apache-2.0 | <https://hackage.haskell.org/package/jose> |
| miso | 1.14.0.0 | BSD-3-Clause | <https://hackage.haskell.org/package/miso> |
| mlkem | 0.2.3.0 | BSD-3-Clause | <https://hackage.haskell.org/package/mlkem> |
| network | 3.2.12.0 | BSD-3-Clause | <https://hackage.haskell.org/package/network> |
| network-uri | 2.6.4.2 | BSD-3-Clause | <https://hackage.haskell.org/package/network-uri> |
| optparse-applicative | 0.19.0.0 | BSD-3-Clause | <https://hackage.haskell.org/package/optparse-applicative> |
| process | 1.6.26.1 | BSD-3-Clause | <https://hackage.haskell.org/package/process> |
| recv | 0.1.3 | BSD-3-Clause | <https://hackage.haskell.org/package/recv> |
| resource-pool | 0.5.1.0 | BSD-3-Clause | <https://hackage.haskell.org/package/resource-pool> |
| sqlite-simple | 0.4.19.0 | BSD-3-Clause | <https://hackage.haskell.org/package/sqlite-simple> |
| stm | 2.5.3.1 | BSD-3-Clause | <https://hackage.haskell.org/package/stm> |
| tagsoup | 0.14.8 | BSD-3-Clause | <https://hackage.haskell.org/package/tagsoup> |
| temporary | 1.3 | BSD-3-Clause | <https://hackage.haskell.org/package/temporary> |
| text | 2.1.3 | BSD-2-Clause | <https://hackage.haskell.org/package/text> |
| time | 1.12.2 | BSD-2-Clause | <https://hackage.haskell.org/package/time> |
| time-hourglass | 0.3.0 | BSD-3-Clause | <https://hackage.haskell.org/package/time-hourglass> |
| time-manager | 0.5.2 | MIT | <https://hackage.haskell.org/package/time-manager> |
| tls | 2.4.6 | BSD-3-Clause | <https://hackage.haskell.org/package/tls> |
| unordered-containers | 0.2.21 | BSD-3-Clause | <https://hackage.haskell.org/package/unordered-containers> |
| validation | 1.2.2 | BSD-3-Clause | <https://hackage.haskell.org/package/validation> |
| wai | 3.2.5 | MIT | <https://hackage.haskell.org/package/wai> |
| wai-extra | 3.1.18 | MIT | <https://hackage.haskell.org/package/wai-extra> |
| warp | 3.4.21 | MIT | <https://hackage.haskell.org/package/warp> |
| webauthn | 0.12.0.0 | Apache-2.0 | <https://hackage.haskell.org/package/webauthn> |

Test-only dependencies (not shipped in the deployed server): hspec
(MIT), QuickCheck (BSD-3-Clause).

The WebAssembly client uses Miso 1.14.0.0 with the GHC 9.14 WebAssembly
backend, plus the same `base`, `aeson`, `bytestring`, `containers` and `text`
packages listed above.

## SQLite

The server links SQLite through `direct-sqlite` and uses its FTS5 extension.
SQLite is in the public domain: <https://sqlite.org/copyright.html>.

## Fonts

The interface uses three typefaces, all distributed under the SIL Open Font
License 1.1. The license files are in `static/fonts/`:

| Typeface | Files | License |
|---|---|---|
| Fraunces | `fraunces-300-900.woff2` | [OFL-Fraunces.txt](static/fonts/OFL-Fraunces.txt) |
| Newsreader | `newsreader-300-800.woff2` | [OFL-Newsreader.txt](static/fonts/OFL-Newsreader.txt) |
| IBM Plex Mono | `ibm-plex-mono-400.woff2`, `-500`, `-600` | [OFL-IBMPlexMono.txt](static/fonts/OFL-IBMPlexMono.txt) |

## Vendored JavaScript

`static/vendor/browser_wasi_shim/` is the
[browser_wasi_shim](https://github.com/bjorn3/browser_wasi_shim) WebAssembly
WASI shim, dual-licensed under Apache-2.0 and MIT; both license texts are
included in that directory (`LICENSE-APACHE`, `LICENSE-MIT`).

`static/app/ghc_wasm_jsffi.js` is generated by GHC's `post-link.mjs` for this
program and is covered by the GHC license above.

## Browser clipper

The browser clipper (`extension/`) is source-only Apache-2.0 code; the
checked-in tree ships no third-party code. Building the optional Defuddle
bundle with `bash scripts/build-extension.sh --with-defuddle` bundles
[Defuddle](https://github.com/kepano/defuddle) 0.19.6 (MIT) with `esbuild` and
writes the license texts of the packages that contributed to the bundle to
`extension/dist/vendor/THIRD-PARTY-NOTICES.txt`. The plain build copies only
the extension's own files.

## Icons

The application icons (`static/icons/`, `static/favicon.svg`,
`static/favicon-fallback.svg`) are original artwork for this project and are
covered by the repository license.

## Optional external programs

These are not distributed with eza; the deployment installs them separately and
eza invokes them at runtime only when configured:

- **monolith** — local page snapshots, MIT, <https://github.com/Y2Z/monolith>
- **Node.js / Defuddle sidecar** — optional extraction bridge (`sidecar/`),
  Node.js MIT; Defuddle and its dependencies are installed by `npm` from that
  directory's lockfile, and their notices live with those packages.

## Pinned TLS, HTTP/2, and crypto stack

The server's passkey and outbound-TLS stack is the one part of the dependency
tree that `flake.nix` overrides on top of nixpkgs: its GHC 9.10 package set does
not ship webauthn 0.12 + crypton 1.1, so the deployment flake pins the exact
generation (`hpkgsUpgraded` in `flake.nix`) that the development build plan
resolved. The rows above for `tls`, `http2`, `http-semantics`, `recv`,
`time-manager`, `jose`, `hpke`, `mlkem`, `crypton-connection`,
`crypton-x509{,-store,-system,-validation}`, `crypton-asn1-*`, `crypton-pem`,
`crypton-socks`, `data-default*`, `ech-config`, `base16*` are those pinned
releases plus the transitive libraries they compile into the server binary.
`jose` is Apache-2.0; every other package in this group is BSD-3-Clause except
`time-manager` (MIT). Versions were read from the resolved
`dist-newstyle/cache/plan.json` and the license fields of the built package
databases.

## Keeping this list current

`bash scripts/check-notices.sh` (run as `devenv shell -- notices`) fails when a
package pinned in the `flake.nix` Hackage overlay is missing from the table or
carries a different version, and with `--plan` it also compares the versions
against the resolved cabal build plan. CI runs
`bash scripts/check-notices.sh --plan` before building the client, so the
notices and the shipped TLS/crypto generation cannot drift silently.

After a dependency change, read the version and license from the installed
package database:

```bash
ghc-pkg field <package> version license
```

For the WebAssembly client, use the same query with `wasm32-wasi-ghc-pkg`.
Hackage links carry the full license text. The Cabal files in the repository
are the source of truth for the direct dependencies; this table records the
resolution used for the release in the repository history.
