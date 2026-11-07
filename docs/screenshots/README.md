# Screenshots

The screenshots come from a demo database with 14 bookmarks and tags for
Haskell, Nix, SQLite, design, and reading. The demo uses the normal server and
the built WASM client; it is not a mockup.

To capture a new set:

1. Create and start a demo database on a spare port.
2. Run `node tests/e2e/capture-screenshots.mjs` with `EZA_BASE` set to that
   server.
3. Inspect the four PNGs before committing them.

The capture script sets up a virtual WebAuthn authenticator, seeds the demo
bookmarks through the API, and writes `library.png`, `detail.png`,
`palette.png`, and `dark.png`.
