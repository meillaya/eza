# Interface design

The interface has one job: find one of thousands of saved links and show enough
context to decide what to do with it. It is built as a catalogue: a ledger of
numbered accessions, a printed record page, and a set of panels for upkeep.
`static/eza.css` implements the system and is described here.

## Tokens

Tokens live at the top of `static/eza.css`. Nothing else declares a colour.

| Token | Paper | Night |
|---|---|---|
| `--paper` | `#F2EDE3` | `#10141F` |
| `--card` | `#FBF8F1` | `#161B28` |
| `--ink` | `#1A2340` | `#E9E3D6` |
| `--muted` | `#6E675C` | `#A9A08F` |
| `--accent` | `#8A2B20` | `#C98A3E` |
| `--rule` | `#D5CBB8` | `#232A3A` |
| `--rule-soft` | `#E2D9C8` | `#1C2230` |
| `--sel` | `#EFE7D8` | `#1A2030` |
| `--hover` | `#F7F2E6` | `#191F2C` |
| `--ok` / `--warn` / `--danger` | `#3F6B4E` / `#8A5A1F` / `#8A2B20` | `#8FB08A` / `#D6B06A` / `#D98A6F` |

Paper is the default and follows the system preference until the reader picks a
theme. The choice is stored in `localStorage` under `eza-theme`. The interface
labels the two themes paper and reading room at night; `data-theme` keeps the
values `light` and `dark`.

## Type

Three families, three jobs. There is no sans-serif in the interface.

| Family | Files | Job |
|---|---|---|
| Fraunces | `/assets/fonts/fraunces-300-900.woff2` | display, page titles, row titles, small caps labels |
| Newsreader | `/assets/fonts/newsreader-300-800.woff2` | reading copy, dialog body, notes |
| IBM Plex Mono | `/assets/fonts/ibm-plex-mono-{400,500,600}.woff2` | every number, date, label and control |

Roles: display 56/60 and 44/48 for page titles, 32/36 for section titles, 24/29
for card titles, 19/25 for ledger row titles, 19/32 Newsreader for reading, 14/20
Plex Mono for controls, 12/18 for data, 10.5/14 for uppercase labels. Mobile
steps down to 34/38 page titles, 17/21 row titles, 17/28 reading. Body text never
goes below 14 px and data or labels never below 12 px. Fraunces is set with a
fixed optical size so every browser draws the same letterforms.

## Layout

- Unit 4 px. Gutters are 36 px on desktop, 40 px on tablet where the rail folds,
  18 px on mobile.
- The ledger is a five column grid: accession number 72 px, title flexible,
  source 210 px, filed date 82 px, tags 152 px. Rows are 52 px tall and 72 px on
  mobile, with year dividers every few dozen rows.
- The record page is a 588 px bounded reading window beside a 300 px
  catalogue record: the extracted text scrolls inside a rounded card while the
  page stays composed. A crumb carries the return path, and the note editor
  sits below the window.
- Panels use a running head with the section links, a page head with the title
  and figures, and then a table or ledger body.
- Auth and share pages are centred printed cards: wordmark, one heading, the
  fields and one action; one quiet secondary link is the only other copy.

## Screens

| Route | Screen |
|---|---|
| `/` | The ledger: masthead, facets, year dividers, rows, field drawer, selection |
| `/inbox` | Unread ledger with mark loaded unread read |
| `/bookmark/:id` | Record: bounded reading window, catalogue record, note, see also, actions |
| `/accessions` | The archive as an index: filing days per year, ranked sources, long tail; a year, day or source opens the ledger filtered |
| `/graph` | The whole library or a local neighbourhood as a canvas: records, tags, resolved wikilinks and tag memberships, layout presets, label modes and colour groups, with pan, zoom, fit, hover preview, click to open, filter and tags toggle |
| `/views` | Saved graph and ledger views: open, set default, rename, duplicate, export and import |
| `/dedup` | Duplicate groups: paged same-URL groups with a one-shot merge, and advisory same-title groups |
| `/tags` | Tag table, case duplicates, near-duplicate pairs |
| `/tags/ai` | Advisory tag suggestions, applied one bookmark at a time |
| `/maintenance` | Dead-link sweep, prune candidates, undo |
| `/account` | Username and role, password, optional passkey second factor, recovery, sessions, tokens, share links, webhooks, rules, import / export, capture; admins also get a users tab |
| `/save` | Quick save from the PWA share target or bookmarklet |
| `/login`, `/setup`, `/recover`, `/account/add-passkey` | Username/password sign-in, optional passkey second factor, first claim, recovery reset |
| `/s/:token` | Read-only share page for a bookmark or saved search |

Ledger rows expose a tick control once the row is hovered or focused. The
sticky selection bar then shows the count and the bulk actions, and keeps
`select page` and `select all matching` available so a selection can be
extended after the first pick. With nothing selected, the ledger foot offers
the same two controls as separate text buttons. A selection is capped at
10,000 records, and the bar is dismissed with `clear` or `Esc`. Each source
cell shows a cached 16px favicon when the domain has one and a printed
monogram otherwise; the icon is one cached asset per domain, not per row.
The field card overlays the right edge of the ledger; the selection bar and
ledger foot keep their actions clear of it, wrapping when the card is open.

Each account has one Argon2id password hash and its own private library
database. The first claim creates the admin account and shows ten recovery
codes once. The admin can add members from Account > users, set a temporary
password, disable or enable an account, and change a role; a member sees no
users tab and cannot read another account's library. A recovery code clears
that account's password and passkeys and opens a password-reset setup page.
A password account can register passkeys and turn on a second factor from
Account > security; with it on, a normal password login yields a short-lived
pending session and then a WebAuthn assertion. A library claimed before
passwords kept its passkey sign-in until a password was set. Sign-in attempts
are rate-limited and locked out in the database; the auth pages keep the flow
itself and leave the deployment rules to the deployment documents.

Account > webhooks subscribes a URL to signed library events. The signing
secret is shown once when the subscription is created; later visits show the
event, status, last error and recent delivery states, with a test delivery
control. Session-only management means a bearer token cannot change a
subscription. Account > users is visible to admins only and lists username,
role, creation time, last login and disabled state, with add, enable, disable,
role, temporary-password and delete actions. Delete asks for the account name
and offers a separate "also delete the library and snapshots" checkbox that is
off by default.

The masthead carries the wordmark, the provenance line, the search line and the
section links: ledger, inbox, graph, views, duplicates, tags, ai tags,
maintenance, accessions and account. A sign-out control sits at the end of the
section links and in the mobile bar, and every account tab repeats it in the
page head. The command palette also offers "Sign out"; an unsaved note asks for
confirmation first. The ledger's facet rail lists the top sources and tags, saved
searches, the unread and dead counts and a weekly filing sparkline; all sources
opens the accessions index.

States are part of the design: fresh library, filtered to nothing, loading, API
error, no extraction, enrichment queued and failed, dead link, no note, no
backlinks, empty inbox, never-run sweep, empty account panels, expired share
link. Every one has copy.

## Graph and accessions

`/graph` draws the whole library on one canvas: a node for every record and
every tag, and a line for each resolved wikilink and each tag membership. The
canvas pans by drag and by the arrow keys, zooms on the wheel and on the `+`
and `-` buttons, and `fit` frames the whole graph; the readout beside the
buttons gives the scale as a percentage, and a hint line below the plate names
the drag, wheel and click actions. Hovering a node opens a preview card: a
record shows its title, domain, filed date, tags and the counts of its
wikilinks and tagged records, and a tag shows its record count. A click on a
record opens the record, a click on a tag opens the ledger filtered by
`tag:<name>`, as do the top tags in the aside, and a click on the empty plate
clears the selection. The filter line narrows the graph by text, the tags
toggle shows or hides the tag nodes, their membership lines and their click
targets, and `Esc` clears the filter line first, then the selection. The status
line counts the records, tags and wikilinks, prints the label count and the
layout source, and under a filter reports the matching records. A record's
graph action opens the same canvas with that record in focus and its preview
pinned. The plate blits a cached overview while it is moving and redraws a
sharp copy at the display resolution once the view settles, so pan and zoom
stay at the refresh rate and the still plate stays crisp.

The graph settings control the scope, the layout and the labels. Scope is the
whole library or a local neighbourhood rooted at a focused record, one to three
hops deep; the local status names the depth, the root record title sits beside
the scope buttons, and the deeplink `/graph?focus=<id>&depth=2&local=1` opens a
local graph directly. The layout control switches the compact, standard and
airy presets, and a preset change refetches only the layout. The labels follow
the `auto`, `tags` and `none` modes from the active view, and the status line
prints how many labels the current view and zoom draw. The first plate takes
each preset's positions from the server: the client asks
`/api/v1/graph/layout` for the active preset, hydrates the positions when the
layout revision matches the graph payload it holds, and falls back to its own
deterministic builder when it does not.

The accessions index turns its marks into the search line: a year opens
`year:2025`, a filing day or busiest-day row opens `day:2025-11-03`, and a
source opens the ledger filtered by that domain. The date operators read the
UTC filing date, and the chips above the ledger name the operators and can be
removed one at a time.

On touch screens the graph pans by drag and zooms with the buttons; pinch does
not zoom the canvas. Below 768 px the filing-day marks are decorative rather
than buttons, and the year, source and busiest-day rows keep the 44 px touch
target that opens the filtered ledger.

## Views and colour groups

Graph settings and ledger searches are saved as declarative views. A graph view
stores the query, the tags toggle, the label mode, the layout preset, the local
depth and the colour groups; a ledger view stores the query and the sort. The
server validates and stores the document, and the client renders it, so no
extension code runs. [extensions.md](extensions.md) is the contract for the
view and webhook surfaces.

Every database seeds a default graph view. `save` writes the current graph state
to the active view and `save as` creates a named view; the ledger rail also
offers save as view for the current search. `/views` lists the saved documents
with a default badge and open, set default, rename, duplicate, export and import
actions. Opening a graph view lands on `/graph`; opening a ledger view lands on
`/` with its query and sort applied. Exactly one default exists per kind;
setting a new default clears the old one in the same transaction, deleting the
default promotes the lowest-id remaining view of that kind, and deleting the
last graph view seeds the default graph view again.

A graph view carries up to 24 ordered colour groups. Each group is a name, a
search query, a `#rrggbb` colour and an enabled flag, evaluated against the same
record and tag fields as the graph filter, and the first enabled match wins. The
aside legend shows a swatch, the group name, the matching record count and an
on/off control; the group editor adds, edits, enables and removes groups with a
live preview, and saving the view persists them. A disabled group paints
nothing.

## Keyboard

| Key | Action |
|---|---|
| `/` | Focus the search line |
| `Shift+K`, `Cmd+K`, `Ctrl+K` | Open the command palette from any screen (`Ctrl/Cmd+K` works while the search line has focus) |
| `j`, `k` | Move the ledger cursor and open its field drawer; bare `k` opens the palette away from the ledger and inbox |
| `Enter` | Open the record under the cursor, or run the palette item |
| `+`, `-` | Zoom the graph in and out |
| `0`, `f` | Fit the whole graph in the canvas |
| Arrow keys | Pan the graph |
| `Esc` | Close the top layer (palette, drawer or dialog) from any focus; on the graph, clear the filter and selection |
| `Cmd+S`, `Ctrl+S` | Save the note on the record page |

The hint under the search line is a `⇧K` button and opens the palette. Bare `k`
moves the ledger cursor on the ledger and inbox; on every other screen it opens
the palette too. The graph focuses its canvas when the page opens, so `+`, `-`,
`0`, `f` and the arrow keys work without tabbing first; `Esc` works from any
focus and clears the graph filter line before the selection.

## Accessibility

Focus is a 2 px accent ring with a 2 px offset and is never removed. Dialogs
trap focus and restore it on close, and the page behind a dialog is inert. Touch
targets are at least 44 px on mobile. Contrast stays at or above 4.5:1 for body
text and 3:1 for large text in both themes; the contrast audit checks every
screen and theme. Status is never carried by colour alone: the word
accompanies the mark. Landmarks are used for the masthead, sections, ledger,
rail, record and dialogs. `prefers-reduced-motion` disables every transition.
The graph canvas is backed by an accessible results list of the top matching
records and by the top-tag buttons in the aside. The canvas pans, zooms and
fits from the keyboard. The scope, depth and layout controls are labelled
button groups with a pressed state, and the colour legend repeats each group as
a name and a count beside its swatch, so a group is never conveyed by colour
alone. The views manager actions are buttons, and its save, import and export
dialogs trap focus like every other dialog.

## Quiet surfaces

Rules are the exception, not the default. Ledger rows, rail blocks, section
heads, panel blocks, account panels and the duplicate groups separate by
spacing, type and hover state; the year headings carry the ledger's structure.
The masthead rule, the year rules, the row hairlines and the explicit `.rule`
dividers are hidden. Dialogs keep their outline because they float above the
page, and form fields keep their borders because those carry state.

The style lives at the end of `static/eza.css` under `QUIET CATALOGUE`.
When adding a surface, reach for spacing or a type change before adding a
border. The palette shows labels only; its hints stay as tooltips.

## Navigation

Opening a record stores the ledger offset. Returning refetches the first page,
then loads further pages until the saved offset is reachable and restores it;
the first paint starts at the top so the ledger is never blank while that
happens. Scroll events from the container remounting do not cancel the restore,
and the seek retries for a few frames until the taller page has been patched,
so a clamped write cannot strand the ledger at the top. Moving between list
routes that are already mounted keeps the live offset.
`tests/e2e/navigation-smoke.mjs` covers the deep case (a 4,000px return that
needs extra pages).

## Import and export

Account > import / export takes a Netscape HTML bookmarks file or a versioned
eza JSON document and appears as a file control with a per-run report.
The same panel carries the two download buttons: `bookmarks.html` is the
Netscape export any browser can import, and `eza-export.json` is the
versioned eza document with highlights, captures, saved searches, rules, views
and clip templates. Both are served with an attachment disposition, so the browser
session keeps the page and saves the file; the library never leaves the
server unless the file is moved. CLI equivalents are
`eza-bookmarks export` / `export --json`.

## About

The About panel names the software behind the library (the repository, the
release page, the Apache-2.0 license, third-party notices, the main libraries
and typefaces) and shows the library figures. The data-ownership actions live
on the import / export panel; About links to it. The notices file at the
repository root is the canonical list, including the dependency versions and
the SIL Open Font License files under `static/fonts/`.
## Voice

Dry, specific, lowercase for controls. Numbers are exact and grouped: 8,988
entries, 4,283 sources, 543 filing days. Dates are `2025.11.03` in data contexts
and `03 nov 2025` in prose. Empty and error states say what happened and what
the reader can do next in one line; a surface that has never run a check says so
instead of showing a zero that looks like a result.

Copy earns its place: it states a fact the reader cannot already see, asks for a
decision, or names a control. Explanatory paragraphs about how the software
works, colophon lines, marketing words and repeated figures are left out. The
structural vocabulary of the catalogue stays (ledger, filed, record, accessions,
marks) because it names the interface, not because it decorates it. There is no
exclamation mark and no emoji.
