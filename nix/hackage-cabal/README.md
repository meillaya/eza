# Hackage cabal-file revisions (vendored)

These `.cabal` files are the **published Hackage revisions** of the pinned
packages in `flake.nix` (`hpkgsUpgraded` overlay). They are copied over the
`.cabal` file contained in the release tarball before `cabal2nix` generates
the Nix expression for the package.

Why: several releases were uploaded with bounds for an older dependency
generation and then revised on Hackage to accept the newer one. The build plan
in `devenv.nix` (cabal) uses the revised files from the Hackage index, but
`cabal2nix` reads the tarball, which still carries the original bounds. Without
these files the Nix build fails at configure time, e.g.:

    crypton-connection-0.4.6:  tls >=2.3.0 && <2.4   (tarball)
                               tls >=2.3.0 && <2.6   (revision 1, used by nixpkgs build)
    crypton-x509-1.9.1:        crypton >=1.1 && <1.2 (tarball)
                               crypton >=1.1 && <2.2 (revision, used by nixpkgs build)

Provenance: extracted verbatim from the `01-index.tar` (Hackage package index)
cached by cabal in the devenv environment; each file corresponds to
`<package>/<version>/<package>.cabal` in that index. Do not edit them. Update
by re-extracting the revision for the version pinned in `flake.nix`.
