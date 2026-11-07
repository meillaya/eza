# eza UI/UX brief

## Feel

Search-first, calm, rounded, dense but breathable. No folder tree. Cards and
pills, soft elevation, generous radii (14–20px), system font, light/dark.

Tokens (also in `static/eza.css`):

- light: bg `#f7f7f5`, surface `#fff`, surface-2 `#f1f1ee`, border
  `#e6e6e1`, text `#171717`, muted `#6f6f6a`, accent `#5b5bd6`.
- dark: bg `#0f0f11`, surface `#17171a`, surface-2 `#1e1e23`, border
  `#2a2a30`, text `#f5f5f4`, muted `#a3a3a0`, accent `#9a9af7`.
- radii: 10/14/20/999px; shadows `0 1px 2px rgba(0,0,0,.04), 0 8px 24px rgba(0,0,0,.06)`.
- spacing 4/8/12/16/24/32; base font 15px; system UI font stack.
- motion 120–180ms ease-out; honour `prefers-reduced-motion`.

## Screens

- `/` library: sticky top bar (brand, search pill, Add, Import, theme/account),
  scope pills (All, Inbox, Graph, Dedup, Tags, AI, Maintenance), tag rail with
  counts, virtualized card grid. Cards: favicon, title (2 lines), domain, tag
  chips, hover actions. Empty state + onboarding. Command palette on `k`.
- `/bookmark/:id`: editable title, URL/open, read toggle, graph link; main
  reader column (extracted text + Extract/Snapshot) and notes column (markdown
  Write/Preview, wikilink autocomplete, tag chips, backlinks with Link action).
  Save button + Ctrl/Cmd+S + dirty guard.
- `/inbox`: unread grid, Mark all above, saved-searches rail.
- `/graph`: SVG neighborhood (1–2 hops, ≤500 nodes), depth/tag/unread/orphan
  filters, pan/zoom, node click → detail, seed picker.
- `/dedup`: candidate groups, keep-one radio, merge, undo.
- `/tags`: stats, case duplicates, fuzzy pairs, junk tags, merge/rename/delete.
- `/tags/ai`: tag bucket picker, per-bookmark suggestions, approve/discard/apply.
- `/maintenance`: dead-link sweep, dead list, prune candidates + confirm + undo.
- `/account`: passkeys, add/rename/delete, regenerate recovery codes, logout.
- `/setup`, `/login`, `/recover`: small centered auth shells (server rendered).

## Virtualized grid

Fixed card height (124px desktop, 140px mobile). Columns from container width
(min card 280px, gap 12px). Render only visible rows ±3 overscan inside a
spacer of `rows * rowHeight`; DOM stays under ~100 cards for 10k items. Fetch
60 more when within 5 rows of the end.

## Accessibility / responsive

Semantic landmarks, labelled controls, focus traps in dialogs, `aria-live`
for search/toasts, visible focus rings, ≥44px touch targets. 3 columns ≥1200,
2 columns 768–1199, 1 column <768. Keyboard: `/` focus search, `k` palette,
`Esc` close, arrows/Enter in palette, Ctrl/Cmd+S save.
