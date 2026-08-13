{
  description = "Reproducible Playwright/Chromium e2e devshell (Playwright 1.62.1) for bookmarks";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # PR #550089 head — the only nixpkgs rev shipping playwright 1.62.1 with
    # browsers byte-identical to npm. Re-point to the merge commit after merge.
    nixpkgs-playwright.url = "github:NixOS/nixpkgs/590d737e9e7cfbc6ee5c569a7683eaa67456a761";
  };
  outputs = { self, nixpkgs, nixpkgs-playwright, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in {
      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          pkgs-playwright = nixpkgs-playwright.legacyPackages.${system};
          packageJson = builtins.fromJSON (builtins.readFile ./package.json);
          npmVersion = packageJson.devDependencies."@playwright/test";
          nixVersion = pkgs-playwright.playwright-driver.version;
        in {
          default = pkgs.mkShell {
            packages = [
              pkgs.bun
              pkgs.nodejs
              pkgs.uv
              pkgs.python312
              pkgs-playwright.playwright-test
              pkgs-playwright.playwright-driver.browsers
            ];
            env = {
              PLAYWRIGHT_BROWSERS_PATH = "${pkgs-playwright.playwright-driver.browsers}";
              PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
              PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS = "true";
              PLAYWRIGHT_INCLUDE_WEBKIT = "1";
            };
            shellHook = ''
              if ! "${pkgs.bun}/bin/bun" -e "process.exit('${npmVersion}' === '${nixVersion}' ? 0 : 1)"; then
                echo "ERROR: @playwright/test version in package.json (${npmVersion}) does not match nixpkgs playwright-driver version (${nixVersion})." >&2
                echo "Run: nix flake update nixpkgs-playwright (after the upstream PR merges) or align the npm version." >&2
                exit 1
              fi
            '';
          };
        });
    };
}
