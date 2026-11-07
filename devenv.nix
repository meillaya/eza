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
    pkgs.fourmolu
    pkgs.hlint
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
    EZA_BIND = "127.0.0.1:8080";
    PUBLIC_ORIGIN = "http://localhost:8080";
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
    echo "  commands: dev web build test lint e2e bench import verify"
  '';

  scripts = {
    dev.exec = "cabal run eza-bookmarks -- serve";
    web.exec = "scripts/build-web.sh";
    build.exec = "cabal build all && scripts/build-web.sh";
    test.exec = "cabal test all";
    lint.exec = "fourmolu --mode check core server web && hlint core server web";
    fmt.exec = "fourmolu --mode inplace core server web";
    e2e.exec = "bun x playwright test";
    bench.exec = "cabal run eza-bench";
    db-init.exec = "cabal run eza-bookmarks -- init";
    import.exec = "cabal run eza-bookmarks -- import netscape";
    export.exec = "cabal run eza-bookmarks -- export";
    verify.exec = "cabal run eza-bookmarks -- verify";
    backup.exec = "cabal run eza-bookmarks -- backup";
    release.exec = "scripts/release.sh";
  };

  processes.server = {
    exec = "cabal run eza-bookmarks -- serve";
    ready.exec = "curl -fsS http://127.0.0.1:8080/healthz";
  };
}
