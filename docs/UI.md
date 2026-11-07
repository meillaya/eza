# Interface design

The interface has one job: find a bookmark quickly and show enough context to
decide what to do with it. Tags replace a folder tree. The layout uses rounded
cards, a tag rail, and one search field.

## Tokens

The design tokens live in `static/eza.css`.

| Token | Light | Dark |
|---|---|---|
| background | `#f7f7f5` | `#0f0f11` |
| surface | `#ffffff` | `#17171a` |
| surface 2 | `#f1f1ee` | `#1e1e23` |
| border | `#e6e6e1` | `#2a2a30` |
| text | `#171717` | `#f5f5f4` |
| muted | `#6f6f6a` | `#a3a3a0` |
| accent | `#5b5bd6` | `#9a9af7` |

Radii are 10, 14, 20, and 999 px. Shadows use two layers, one at 1 px and one
at 8 px. Spacing uses a 4 px scale. Body text is 15 px in the system UI font.
Motion runs for 120 to 180 ms with an ease-out curve, and the stylesheet honors
`prefers-reduced-motion`.

## Library

The library fills the first screen. The top bar holds the brand, the search
field, Add, Import, theme, and account controls. A scope row switches between
All, Inbox, Graph, Duplicates, Tags, AI tags, Maintenance, and Account. The tag
rail lists tags with counts and saved searches.

The card grid uses fixed-height cards: 124 px on desktop and 140 px on mobile.
Columns come from the container width, with a 280 px minimum card and a 12 px
gap. A card shows the favicon, the title on two lines, the domain, and the tag
chips. Hover actions cover open, read, and delete.

The grid renders only visible rows plus three rows of overscan. It fetches 60
more rows when the viewport is within five rows of the end. The DOM stays under
about 100 cards for a 10,000-item library.

## Detail

The detail view shows an editable title, the URL, a read toggle, and a graph
link. The reader column holds extracted text plus Extract and Snapshot. The
notes column holds the markdown editor, a preview, wikilink autocomplete, tag
chips, and backlinks.

Save writes the title, note, read flag, and tags in one patch. The keyboard
shortcut is Ctrl+S or Cmd+S. Leaving the page with unsaved changes opens a
confirmation dialog.

## Other screens

| Route | Content |
|---|---|
| `/inbox` | Unread grid, mark-all-above, saved searches |
| `/graph` | SVG neighborhood for one or two hops, depth and tag filters, pan and zoom |
| `/dedup` | Candidate groups, keep-one choice, merge, undo |
| `/tags` | Tag stats, case duplicates, fuzzy pairs, merge, rename, delete |
| `/tags/ai` | Tag bucket picker, per-bookmark suggestions, apply or discard |
| `/maintenance` | Dead-link sweep, dead list, prune candidates, confirm, undo |
| `/account` | Passkeys, recovery code regeneration, sign out |
| `/setup`, `/login`, `/recover` | Centered auth pages rendered by the server |

## Accessibility

The client uses semantic landmarks, labelled controls, focus traps in dialogs,
and live regions for search results and toasts. Focus rings stay visible.
Touch targets measure at least 44 px.

The grid uses three columns at 1200 px and wider, two columns from 768 to
1199 px, and one column below 768 px.

Keyboard shortcuts:

| Key | Action |
|---|---|
| `/` | Focus search |
| `k` | Open the command palette |
| `Esc` | Close the palette or dialog |
| arrows, Enter | Move and confirm in the palette |
| Ctrl+S, Cmd+S | Save the current bookmark |
