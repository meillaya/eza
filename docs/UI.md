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
- The record page is a 588 px reading column beside a 300 px catalogue record,
  with a crumb and accession rule above and a note editor below the record.
- Panels use a running head with the section links, a page head with the title
  and figures, and then a table or ledger body.
- Auth and share pages are centred printed cards: wordmark, one rule, one action.

## Screens

| Route | Screen |
|---|---|
| `/` | The ledger: masthead, facets, year dividers, rows, field drawer, selection |
| `/inbox` | Unread ledger with mark all above read |
| `/bookmark/:id` | Record: reading column, catalogue record, note, see also, actions |
| `/accessions` | The archive as an index: filing days per year, ranked sources, long tail |
| `/graph` | Tag neighbourhood around a seed bookmark |
| `/dedup` | Duplicate groups and keep-one merges |
| `/tags` | Tag table, case duplicates, near-duplicate pairs |
| `/tags/ai` | Advisory tag suggestions, applied one bookmark at a time |
| `/maintenance` | Dead-link sweep, prune candidates, undo |
| `/account` | Username, password, optional passkey second factor, recovery, sessions, tokens, share links, rules, import, capture |
| `/save` | Quick save from the PWA share target or bookmarklet |
| `/login`, `/setup`, `/recover`, `/account/add-passkey` | Username/password sign-in, optional passkey second factor, first claim, recovery reset |
| `/s/:token` | Read-only share page for a bookmark or saved search |

One username and one Argon2id password hash open the library. The setup page
chooses them and shows ten recovery codes once. A recovery code clears the
password and passkeys and opens a password-reset setup page. A password
account can register passkeys and turn on a second factor from Account >
security; with it on, a normal password login yields a short-lived pending
session and then a WebAuthn assertion. A library claimed before passwords
kept its passkey sign-in until a password was set. The auth pages explain the
secure origin rule, the IP-literal RP-ID restriction, and the `set-password`
CLI alternative. Sign-in attempts are rate-limited and locked out in the
database.

The masthead carries the wordmark, the provenance line, the search line and the
section links. The ledger's facet rail lists sources with leader dots, tags in
two columns, status, filing activity and the accessions link.

States are part of the design: fresh library, filtered to nothing, loading, API
error, no extraction, enrichment queued and failed, dead link, no note, no
backlinks, empty inbox, never-run sweep, empty account panels, expired share
link. Every one has copy.

## Keyboard

| Key | Action |
|---|---|
| `/` | Focus the search line |
| `Shift+K`, `Cmd+K`, `Ctrl+K` | Open the command palette |
| `j`, `k` | Move the ledger cursor and open its field drawer |
| `Enter` | Open the record under the cursor, or run the palette item |
| `Esc` | Close the palette, drawer or dialog; clear the query when search has focus |
| `Cmd+S`, `Ctrl+S` | Save the note on the record page |

Bare `k` moves the ledger cursor, so the palette needs the shift or command
modifier. This is recorded here because the two habits collide.

## Accessibility

Focus is a 2 px accent ring with a 2 px offset and is never removed. Dialogs
trap focus and restore it on close, and the page behind a dialog is inert. Touch
targets are at least 44 px on mobile. Contrast stays at or above 4.5:1 for body
text and 3:1 for large text in both themes; the audit in the design package
checks every screen and theme. Status is never carried by colour alone: the word
accompanies the mark. Landmarks are used for the masthead, sections, ledger,
rail, record and dialogs. `prefers-reduced-motion` disables every transition.

## Voice

Dry, first person, specific. Numbers are exact and grouped: 8,988 entries, 4,283
sources, 543 filing days. Dates are `2025.11.03` in data contexts and `03 nov
2025` in prose. Empty and error states say what happened and what the reader can
do next. There is no marketing copy, no exclamation marks and no emoji. Every
number in the interface comes from the database; a surface that has never run a
check says so instead of showing a zero that looks like a result.
