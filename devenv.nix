{ pkgs, inputs, config, ... }:
let
  wasm = inputs.ghc-wasm-meta.packages.${pkgs.stdenv.system};
in
{
  languages.haskell = {
    enable = true;
    package = pkgs.haskell.compiler.ghc910;
    cabal.enable = true;
    lsp.enable = false;
    stack.enable = false;
  };

  packages = [
    wasm.wasm32-wasi-ghc-9_14
    wasm.wasm32-wasi-cabal-9_14
    wasm.wasi-sdk
    wasm.binaryen
    wasm.wasmtime

    pkgs.bun
    pkgs.nodejs_22
    pkgs.sqlite
    pkgs.curl
    pkgs.jq
    # gzip is used by scripts/build-web.sh for the precompressed <file>.gz
    # sidecars the server serves with Content-Encoding: gzip. Listing it here
    # keeps the build off the host PATH and makes a missing gzip a shell
    # problem, not a silently skipped compression step.
    pkgs.gzip
    # python3 with Draft 2020-12 JSON-Schema validation for
    # scripts/check-specs.sh, plus fontTools and brotli for the README wordmark
    # generator in docs/figures.
    (pkgs.python3.withPackages (ps: [ ps.jsonschema ps.fonttools ps.brotli ]))
    pkgs.fourmolu
    pkgs.hlint
    # TLA+ model checker (tlc) for the spec/ checks.
    pkgs.tlaplus
    pkgs.pkg-config
    pkgs.zlib
    pkgs.openssl
    pkgs.cacert
    pkgs.monolith
    pkgs.playwright-driver.browsers
    pkgs.secretspec
  ];

  env = {
    EZA_DATA_DIR = "${config.devenv.root}/data";
    EZA_STATIC_DIR = "${config.devenv.root}/static";
    EZA_BIND = "127.0.0.1:8000";
    PUBLIC_ORIGIN = "http://localhost:8000";
    CABAL_DIR = "${config.devenv.root}/.devenv/cabal";
    PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
    SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

    # SecretSpec (devenv.yaml: secretspec.enable) resolves the manifest into
    # the shell environment. Optional secrets are empty when unset.
    ANTHROPIC_API_KEY = config.secretspec.secrets.ANTHROPIC_API_KEY or "";
    OPENAI_API_KEY = config.secretspec.secrets.OPENAI_API_KEY or "";
  };

  enterShell = ''
    echo "eza dev shell"
    echo "  ghc:  $(ghc --numeric-version 2>/dev/null || echo missing)"
    echo "  wasm: $(wasm32-wasi-ghc --numeric-version 2>/dev/null || echo missing)"
    echo "  commands: dev web build test lint docs spec e2e bench import verify"
  '';

  scripts = {
    dev.exec = "cabal run eza-bookmarks -- serve";
    web.exec = "scripts/build-web.sh";
    bundle.exec = "scripts/bundle-web.sh --no-build";
    build.exec = "cabal build all && scripts/build-web.sh";
    test.exec = "cabal test all";
    lint.exec = "fourmolu --mode check core server web web-logic && hlint core server web web-logic";
    docs.exec = "bash scripts/check-docs.sh";
    spec.exec = "bash scripts/check-specs.sh";
    # THIRD-PARTY-NOTICES.md vs the flake's pinned dependency set (and, when a
    # cabal build plan exists, the resolved versions).
    notices.exec = "bash scripts/check-notices.sh --plan";
    fmt.exec = "fourmolu --mode inplace core server web web-logic";
    e2e.exec = "bash scripts/e2e.sh";
    bench.exec = "cabal run eza-bookmarks -- bench --iterations 100";
    db-init.exec = "cabal run eza-bookmarks -- init";
    import.exec = "cabal run eza-bookmarks -- import";
    export.exec = "cabal run eza-bookmarks -- export";
    verify.exec = "cabal run eza-bookmarks -- verify";
    backup.exec = "cabal run eza-bookmarks -- backup";
    release.exec = "scripts/release.sh";
  };

  processes.server = {
    exec = "cabal run eza-bookmarks -- serve";
    ready.exec = "curl -fsS http://127.0.0.1:8000/healthz";
  };
}
