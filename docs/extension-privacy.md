# eza clipper privacy policy

The eza clipper is the browser extension for a self-hosted eza library. This
policy describes what the extension does with data. It applies to the Chrome
and Firefox builds of the extension.

- Effective date: 2026-11-17
- Applies to: eza clipper 0.2.0 and later

## The short version

The extension talks only to the eza server **you configure**. It does not send
data to the extension's developer, and it has no analytics, telemetry,
advertising, crash reporting, or third-party network calls.

The extension needs the address of the page in your active tab so it can tell
you whether that page is already in your library. When you add a bookmark it
also sends the title and any tags you enter. Page content, including selected
text, is sent only when you explicitly choose **Add page text** or **Add
selection**.

A capture token that you create in eza is stored in this browser profile and
sent only to your server in an `Authorization` header.

## What is handled, and when

| Data | When | Where it goes |
| --- | --- | --- |
| The active tab's address and title | Whenever the extension checks the saved-page indicator, and whenever you open its popup or use an add action | Your eza server, as a `GET /api/v1/bookmarks/lookup` or `POST /api/v1/quick-save` request |
| The title, tags, and bookmark address you confirm | When you choose **Add bookmark**, or an add context-menu or keyboard action | Your eza server, as `POST /api/v1/quick-save` |
| The page's readable text and selected text | Only when you choose **Add page text**, **Add selection**, or the matching context-menu/keyboard action | Your eza server, as `POST /api/v1/clip` |
| The capture token you paste into Options | When you save the extension settings | This browser profile's extension storage; sent only to your server in an `Authorization` header |
| The server address and the default template id/name | When you save the extension settings | This browser profile's extension storage |

The extension does not read or transmit your full browsing history. It asks
the browser for the **currently active tab** when it refreshes the toolbar
status, and it reads page content only after you invoke a page-text action.

## Where the data goes

The extension sends data to the eza server address you enter in its options
page. That server is the self-hosted instance you or your administrator
operate. The extension developer does not receive, store, sell, or share that
data, and there is no intermediary service.

The eza server stores the bookmarks, captures, tags, and token hashes according
to its own configuration and [database rules](../AGENTS.md#database-rules).
Backups are kept on that host. Deleting a bookmark in eza, or revoking the
capture token in **Account → Tokens**, ends the server-side data associated
with that action; the token is only a credential and is stored as a hash by
the server.

## Browser permissions and why they exist

| Permission | Why the extension asks for it |
| --- | --- |
| `tabs` | Read the active tab's address and title so the toolbar icon can show whether the page is already saved. The extension does not enumerate or retain other tabs. |
| `activeTab` | Read the current page only after you click the extension, use its context menu, or press its keyboard shortcut. |
| `scripting` | Extract readable page text or the selected passage after one of those user actions. No content script runs at page load. |
| `storage` | Keep the server address, capture token, and defaults in this browser profile. |
| `contextMenus` | Offer the add actions in the page context menu. |
| Optional host access to your server | The extension asks for permission for the one server origin you configure, at the moment you grant it in Options. It has no static access to arbitrary sites. |

Firefox additionally asks for consent to the data categories declared in the
extension manifest:

- **Browsing activity** — the active page address used for the saved-page
  indicator and add actions.
- **Bookmarks** — the title, address, and tags of a bookmark you add.
- **Website content** (optional) — the readable page text or selection you
  explicitly choose to capture. Firefox shows this as an optional permission;
  declining it leaves **Add bookmark** working and disables page-text capture.

## Retention and control

- The extension keeps its settings and capture token in extension-local
  storage until you clear them, remove the extension, or revoke the token in
  eza.
- Saved-page lookup results are kept in memory for at most 60 seconds and are
  discarded when the extension's background context stops. They are not
  written to storage.
- Your eza server owns the bookmarks and captures. Retain, export, or delete
  them there; the extension is only a client.
- Revoking the capture token in eza invalidates the copy stored in the
  extension immediately on the server side. Remove the token from Options if
  you also want to clear the browser copy.

## Chrome Web Store and Firefox Add-ons disclosures

The store listings use this policy as their privacy-policy URL. The Chrome
listing discloses web history and website content as data used for the
extension's single purpose. The Firefox listing declares the manifest's
required `browsingActivity` and `bookmarksInfo` permissions and the optional
`websiteContent` permission described above.

## Changes

A change that alters what the extension sends, or where it sends it, updates
this document and the extension version. The extension's manifest data
collection declaration is updated at the same time; Firefox shows the change
on update when required data changes.

## Contact

Questions or issues: open an issue at
<https://github.com/meillaya/eza/issues>. Do not include capture tokens,
passwords, or private page content in an issue.
