# Store submission package

This directory holds the listing copy, permission justifications, and the
submission checklist for the Chrome Web Store and Firefox Add-ons (AMO)
listings. The store packages themselves are build outputs, not tracked files.

## Build the packages

From the repository root:

```bash
cd extension
npm test          # manifest, source, icon, and build checks
npm run build     # dist/chrome, dist/firefox, and both ZIPs
```

Outputs:

```
extension/dist/chrome/                              load-unpacked Chrome build
extension/dist/firefox/                             Firefox package directory
extension/dist/eza-clipper-<version>-chrome.zip     Chrome Web Store upload
extension/dist/eza-clipper-<version>-firefox.zip    AMO upload
```

The plain build uses the built-in DOM extractor. It contains no third-party
code, no remote code, no `node_modules`, and no test files. `--with-defuddle`
is a local power-user build only and must not be uploaded to either store.

Before uploading, confirm the version in `extension/manifest.json`,
`extension/package.json`, and `extension/src/version.js` is the same and higher
than the previously published version, and that both ZIPs unpack with
`manifest.json` at the archive root:

```bash
unzip -l extension/dist/eza-clipper-<version>-chrome.zip | head
unzip -l extension/dist/eza-clipper-<version>-firefox.zip | head
```

## Chrome Web Store

Account requirement: a Chrome Web Store developer account (one-time
registration fee) and a verified developer email.

1. Open the [Chrome Web Store Developer Dashboard](https://chrome.google.com/webstore/devconsole).
2. **New item** → upload `eza-clipper-<version>-chrome.zip`.
3. Listing:
   - **Name**: `eza clipper`
   - **Summary**: `Add the current page to your eza library and see when it is already saved.`
   - **Category**: Productivity → Tools
   - **Language**: English
   - **Description**:

     > eza is a private, self-hosted bookmark catalogue. This extension is its
     > browser companion.
     >
     > **Add bookmark** files the current page in your eza library in one
     > click, with optional tags. The toolbar icon shows a small check when the
     > page is already saved and the tooltip names the saved bookmark, so you
     > never add the same page twice. Saved pages open directly in eza.
     >
     > **Add page text** saves the readable article or the selected passage to
     > the bookmark when you need a reading copy; the server can also fetch and
     > extract pages in the background. The extension connects only to the eza
     > server address you enter in its options, and a capture token you create
     > in your own account. There is no account sign-up, no analytics, and no
     > developer server.
     >
     > eza is open source (Apache-2.0) and self-hosted. You need your own eza
     > instance to use the extension.

4. **Privacy practices**: the extension handles web history (the active page
   address and title), bookmark information (the title, address, and tags you
   add), and website content (only when you choose a page-text action). It does
   not sell data, does not use it for advertising or creditworthiness, and
   sends it only to the eza server you configure. No developer server exists.
   Use the privacy policy URL that publishes `docs/extension-privacy.md`.
5. **Permissions justification**:
   - `tabs` — Reads the active tab's URL and title so the toolbar icon can
     tell the user whether the current page is already in their library. The
     extension does not read browsing history, does not enumerate other tabs,
     and does not retain the data except for a 60-second in-memory lookup
     cache.
   - `activeTab` and `scripting` — Read the current page only after the user
     clicks the extension, uses its context menu, or presses its shortcut, and
     only to save the readable text or selected passage the user requested.
     No content script runs at page load.
   - `storage` — Stores the user's server address, capture token, and default
     template in the browser profile.
   - `contextMenus` — Provides the add-bookmark, add-page-text, and
     add-selection entries in the page context menu.
   - `optional_host_permissions` — Accesses only the eza server origin the user
     grants in Options; there is no static host permission.
6. **Remote code**: answer **No**. The extension ships all of its JavaScript.
   It uses no `eval`, no remote scripts, and no dynamic module loading.
7. **Screenshots**: upload at least one 1280×800 (or 640×400) PNG. Required
   states: the popup on an unsaved page with **Add bookmark**, the popup on a
   saved page with **In your library** and **Open in eza**, and the options page
   with the connection test. A 440×280 promotional tile is optional.
8. Submit for review.

The Chrome build declares `minimum_chrome_version` 116. It has no
`browser_specific_settings` key and no `browser.scripts` fallback.

## Firefox Add-ons (AMO)

Account requirement: an addons.mozilla.org developer account.

1. Open the [AMO Developer Hub](https://addons.mozilla.org/developers/).
2. **Submit a New Add-on** → upload
   `eza-clipper-<version>-firefox.zip`.
3. Choose **On this site** for a listed add-on (the normal store install), or
   **On your own** for a self-distributed signed build.
4. Listing:
   - **Name**: `eza clipper`
   - **Summary**: `Add the current page to your eza library and see when it is already saved.`
   - **Categories**: Bookmarks; Productivity
   - **License**: Apache-2.0
   - **Support site**: <https://github.com/meillaya/eza/issues>
   - **Privacy policy**: the published `docs/extension-privacy.md`
   - **Description**: reuse the Chrome description above.
5. **Data collection**: declare
   - required: Browsing activity, Bookmarks
   - optional: Website content
   Match the manifest's `browser_specific_settings.gecko.data_collection_permissions`
   block. The extension uses the optional permission for page-text capture; it
   requests consent from the popup before the first capture.
6. **Reviewer notes**:
   - The submitted ZIP is the complete source. There is no build step, no
     minifier, no bundler, and no remote code.
   - `browser.scripts` is used because Firefox does not run MV3
     `background.service_worker`; Chrome uses the service-worker key in the
     separately built Chrome ZIP.
   - The extension contacts only the server URL the user enters in Options;
     no developer endpoint is contacted.
   - The `tabs` permission is required for the active-page saved-state
     indicator. Page content is read only after an explicit user action.
7. **Screenshots**: reuse the Chrome screenshots (1280×800 or 640×400).
8. Submit for review. The signed `.xpi` is available from the AMO listing; a
   self-distributed signed build can also be produced with
   `npx web-ext sign --source-dir extension/dist/firefox --api-key ... --api-secret ...`.

The Firefox build declares `strict_min_version` 140.0, the
`browser_specific_settings.gecko.id` value `eza-clipper@eza.dev`, and
`data_collection_permissions`. Replace the add-on ID before the first
submission if a different permanent ID is preferred; changing it after
publication is not possible.

## Screenshot capture

The screenshots must show the real extension, not a mock. After loading
`extension/dist/chrome` or the Firefox build and configuring a test server:

1. Open the popup on a page that is not saved, with the title/tags fields
   visible, and capture a 1280×800 PNG.
2. Add the bookmark, reopen the popup on the same page, and capture the
   **In your library** state with **Open in eza**.
3. Open Options, run **Test connection**, and capture the connected state.
4. Keep the screenshots free of real server hostnames, tokens, page content,
   and personal bookmarks. Use a throwaway instance and a page such as
   `https://example.com`.

Chrome suggests 1280×800 or 640×400; AMO accepts PNG or JPG at a comparable
size. Store listings also need a 128×128 icon, which is already in the ZIP at
`icons/icon-128.png`.

## Updates

1. Bump the version in `extension/manifest.json`, `extension/package.json`,
   `extension/package-lock.json`, `extension/src/version.js`, and the options
   page version rendering.
2. Run `npm test && npm run build`.
3. Upload the new ZIP in the developer dashboard / AMO hub. Chrome and AMO
   keep the existing listing, screenshots, and privacy answers; update the
   listing only when the feature or data description changes.
4. If the data categories change, update `docs/extension-privacy.md` and the
   Firefox `data_collection_permissions` block in the same release.

## CI and release artifacts

CI runs `npm test` and `npm run build` for the extension. The release workflow
attaches both ZIPs to the GitHub release. Store upload remains a manual,
credentialed step; no store API keys are stored in the repository.
