// Bookmarks — frontend controller.
// Vanilla JS, no build step. Talks to the JSON API.
// One module serves two pages: the search/grid shell (/) and the bookmark
// detail/reader page (/bookmark/{id}). Each page's wiring runs only when its
// root element exists, so loading this module on either page is safe.

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

function escapeHtml(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c]));
}

function debounce(fn, ms) {
  let t;
  return (...args) => {
    clearTimeout(t);
    t = setTimeout(() => fn(...args), ms);
  };
}

function csrfToken() {
  const c = document.cookie.split("; ").find((c) => c.startsWith("csrf_token="));
  return c ? c.slice("csrf_token=".length) : "";
}

// ---------------------------------------------------------------------------
// Grid page (/) — search, tag filter, infinite scroll, add, import, delete
// ---------------------------------------------------------------------------

function initGridPage() {
  const PAGE_SIZE = 60;
  const SEARCH_DEBOUNCE_MS = 180;

  const state = {
    q: "",
    tags: [],          // array of tag names currently filtered
    offset: 0,
    total: 0,
    loading: false,
    exhausted: false,
  };

  function cardHtml(b) {
    const tagsHtml = (b.tags || []).map((t) => `<span class="tag">${escapeHtml(t)}</span>`).join("");
    const title = b.title || b.url;
    const favicon = b.favicon_url || "/static/favicon-fallback.svg";
    return `
      <article class="card" data-id="${b.id}" style="contain-intrinsic-size: 0 92px;">
        <a class="card-link" href="${escapeHtml(b.url)}" target="_blank" rel="noopener noreferrer">
          <img class="favicon" src="${escapeHtml(favicon)}" alt="" loading="lazy"
               onerror="this.onerror=null;this.src='/static/favicon-fallback.svg'">
          <div class="card-body">
            <div class="card-title">${escapeHtml(title)}</div>
            <div class="card-domain">${escapeHtml(b.domain)}</div>
          </div>
        </a>
        ${tagsHtml ? `<div class="card-tags">${tagsHtml}</div>` : ""}
        <div class="card-footer">
          <a class="card-detail" href="/bookmark/${b.id}">Details</a>
        </div>
        <button class="card-delete" data-id="${b.id}" title="Delete" aria-label="Delete">×</button>
      </article>
    `;
  }

  function buildQuery() {
    const params = new URLSearchParams();
    if (state.q) params.set("q", state.q);
    if (state.tags.length) params.set("tags", state.tags.join(","));
    params.set("offset", String(state.offset));
    params.set("limit", String(PAGE_SIZE));
    return params.toString();
  }

  async function fetchPage({ replace = false } = {}) {
    if (state.loading) return;
    state.loading = true;
    grid.dataset.loading = "true";

    try {
      const resp = await fetch("/api/search?" + buildQuery());
      if (!resp.ok) throw new Error("search failed: " + resp.status);
      const data = await resp.json();
      state.total = data.total;

      if (replace) {
        grid.innerHTML = "";
      }
      if (data.items.length === 0 && replace) {
        empty.hidden = false;
      } else {
        empty.hidden = true;
      }
      const frag = document.createRange().createContextualFragment(
        data.items.map(cardHtml).join("")
      );
      grid.appendChild(frag);

      state.offset += data.items.length;
      state.exhausted = state.offset >= state.total;
      grid.dataset.exhausted = String(state.exhausted);
    } catch (err) {
      console.error(err);
    } finally {
      state.loading = false;
      grid.dataset.loading = "false";
    }
  }

  function refresh() {
    state.offset = 0;
    state.exhausted = false;
    fetchPage({ replace: true });
  }

  const debouncedSearch = debounce(refresh, SEARCH_DEBOUNCE_MS);

  const grid = $("#grid");
  const empty = $("#empty");
  const searchInput = $("#search");
  const tagbar = $("#tagbar");
  const modal = $("#add-modal");
  const palette = $("#quick-switcher");

  searchInput.addEventListener("input", (e) => {
    state.q = e.target.value.trim();
    debouncedSearch();
  });

  // Tag filter — clicking toggles, multiple tags ANDed.
  tagbar.addEventListener("click", (e) => {
    const chip = e.target.closest(".chip");
    if (!chip) return;
    const tag = chip.dataset.tag || "";
    if (tag === "") {
      state.tags = [];
    } else {
      const idx = state.tags.indexOf(tag);
      if (idx >= 0) state.tags.splice(idx, 1);
      else state.tags.push(tag);
    }
    // Update chip visual state.
    $$(".chip", tagbar).forEach((c) => {
      const t = c.dataset.tag || "";
      c.classList.toggle("active", t === "" ? state.tags.length === 0 : state.tags.includes(t));
    });
    refresh();
  });

  // Infinite scroll via IntersectionObserver.
  const sentinel = document.createElement("div");
  sentinel.id = "sentinel";
  grid.parentNode.insertBefore(sentinel, grid.nextSibling);
  new IntersectionObserver(
    (entries) => {
      if (entries[0].isIntersecting && !state.loading && !state.exhausted) {
        fetchPage();
      }
    },
    { rootMargin: "400px" }
  ).observe(sentinel);

  // Delete (event delegation).
  grid.addEventListener("click", async (e) => {
    const btn = e.target.closest(".card-delete");
    if (!btn) return;
    const id = btn.dataset.id;
    btn.disabled = true;
    try {
      const resp = await fetch(`/api/bookmarks/${id}`, { method: "DELETE" });
      if (!resp.ok) throw new Error("delete failed");
      const card = btn.closest(".card");
      card.style.transition = "opacity .15s, transform .15s";
      card.style.opacity = "0";
      card.style.transform = "scale(.96)";
      setTimeout(() => card.remove(), 150);
      state.total = Math.max(0, state.total - 1);
    } catch (err) {
      console.error(err);
      btn.disabled = false;
    }
  });

  // Add modal. openAddModal(url) is also used by the quick switcher's
  // "add as new bookmark" fallback, which prefills the URL field.
  function openAddModal(url = "") {
    $("input[name=url]", modal).value = url;
    $("input[name=tags]", modal).value = "";
    modal.showModal();
    $("input[name=url]", modal).focus();
  }
  $("#add-btn").addEventListener("click", () => openAddModal());
  modal.addEventListener("click", (e) => {
    if (e.target === modal || e.target.matches("[data-close]")) modal.close();
  });
  $("#add-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const fd = new FormData(e.target);
    const resp = await fetch("/api/bookmarks", { method: "POST", body: fd });
    if (resp.ok) {
      modal.close();
      refresh();
    } else {
      const detail = await resp.json().catch(() => ({}));
      alert(detail.detail || "Could not add bookmark");
    }
  });

  // Importer.
  $("#import-input").addEventListener("change", async (e) => {
    const file = e.target.files[0];
    if (!file) return;
    const fd = new FormData();
    fd.append("file", file);
    const resp = await fetch("/api/import", { method: "POST", body: fd });
    if (resp.ok) {
      const data = await resp.json();
      alert(`Imported ${data.inserted} bookmarks. Reloading…`);
      location.reload();
    } else {
      alert("Import failed");
    }
    e.target.value = "";
  });

  // Quick switcher palette (todo 22): a command palette over /api/search
  // (small limit). Plain "k" opens it; ↑↓ move the selection; Enter opens
  // the selected bookmark's detail page; when nothing matches, an
  // "add as new bookmark" fallback prefills the Add modal with the query.
  // The binding is deliberately NOT Ctrl+K — that key is reserved by Chrome's
  // omnibox and Firefox's search bar, so page JS can never intercept it.

  const QS_LIMIT = 8;
  const qsInput = $("#qs-input");
  const qsResults = $("#qs-results");
  let qsItems = [];
  let qsSelected = -1;
  let qsCreateNew = false;
  let qsFetchSeq = 0;

  function qsOptionCount() {
    return qsItems.length + (qsCreateNew ? 1 : 0);
  }

  function qsRender() {
    const rows = qsItems.map((it, i) => {
      const title = it.title || it.url;
      return `
        <button type="button" role="option" aria-selected="${i === qsSelected}"
                class="qs-item${i === qsSelected ? " selected" : ""}" data-id="${it.id}">
          <span class="qs-title">${escapeHtml(title)}</span>
          <span class="qs-url">${escapeHtml(it.url)}</span>
        </button>`;
    });
    if (qsCreateNew) {
      const i = qsItems.length;
      rows.push(`
        <button type="button" role="option" aria-selected="${i === qsSelected}"
                class="qs-item qs-create${i === qsSelected ? " selected" : ""}" data-action="create">
          <span class="qs-title">+ Add as new bookmark</span>
          <span class="qs-url">${escapeHtml(qsInput.value.trim())}</span>
        </button>`);
    }
    qsResults.innerHTML = rows.length
      ? rows.join("")
      : '<div class="qs-empty">Type to search titles and URLs…</div>';
  }

  async function qsFetch(q) {
    const seq = ++qsFetchSeq;
    try {
      const params = new URLSearchParams({ q, limit: String(QS_LIMIT) });
      const resp = await fetch("/api/search?" + params);
      if (!resp.ok) throw new Error("quick search failed: " + resp.status);
      const data = await resp.json();
      if (seq !== qsFetchSeq) return;
      qsItems = data.items || [];
      qsCreateNew = q.trim() !== "" && qsItems.length === 0;
      qsSelected = qsOptionCount() > 0 ? 0 : -1;
      qsRender();
    } catch (err) {
      console.error(err);
    }
  }

  const qsDebounced = debounce(() => {
    const q = qsInput.value.trim();
    if (!q) {
      qsItems = [];
      qsCreateNew = false;
      qsSelected = -1;
      qsRender();
      return;
    }
    qsFetch(q);
  }, 180);

  function qsActivate() {
    if (qsSelected >= 0 && qsSelected < qsItems.length) {
      const id = qsItems[qsSelected].id;
      palette.close();
      window.location.href = `/bookmark/${id}`;
      return;
    }
    if (qsCreateNew && qsSelected === qsItems.length) {
      const q = qsInput.value.trim();
      palette.close();
      if (q) openAddModal(q);
    }
  }

  function openPalette() {
    qsItems = [];
    qsCreateNew = false;
    qsSelected = -1;
    qsFetchSeq++;
    qsInput.value = "";
    qsRender();
    palette.showModal();
    qsInput.focus();
  }

  qsInput.addEventListener("input", qsDebounced);
  qsInput.addEventListener("keydown", (e) => {
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      const total = qsOptionCount();
      if (total === 0) return;
      const delta = e.key === "ArrowDown" ? 1 : -1;
      qsSelected = (qsSelected + delta + total) % total;
      qsRender();
    } else if (e.key === "Enter") {
      e.preventDefault();
      qsActivate();
    }
  });
  qsResults.addEventListener("click", (e) => {
    const btn = e.target.closest(".qs-item");
    if (!btn) return;
    const id = btn.dataset.id;
    palette.close();
    if (id) {
      window.location.href = `/bookmark/${id}`;
    } else if (btn.dataset.action === "create") {
      const q = qsInput.value.trim();
      if (q) openAddModal(q);
    }
  });
  palette.addEventListener("click", (e) => {
    if (e.target === palette) palette.close();
  });
  palette.addEventListener("close", () => {
    if (!modal.open) searchInput.focus();
  });

  // Keyboard shortcuts. "k" (no modifier — Ctrl+K is reserved by Chrome's
  // omnibox and Firefox's search bar) opens the quick switcher; "/" focuses
  // search; Escape closes whichever modal is open. None fire while typing in
  // an input/textarea/contenteditable or while a modal dialog is open.
  document.addEventListener("keydown", (e) => {
    const target = e.target;
    const typing = target instanceof HTMLElement && (
      target.tagName === "INPUT" || target.tagName === "TEXTAREA" || target.isContentEditable
    );
    if (e.key === "k" && !e.ctrlKey && !e.metaKey && !e.altKey && !e.shiftKey
        && !typing && !modal.open && !palette.open) {
      e.preventDefault();
      openPalette();
    } else if (e.key === "/" && !typing && !modal.open && !palette.open) {
      e.preventDefault();
      searchInput.focus();
    } else if (e.key === "Escape" && modal.open) {
      modal.close();
    }
  });
}

// ---------------------------------------------------------------------------
// Detail page (/bookmark/{id}) — reader, note editor, tags, explicit save
// ---------------------------------------------------------------------------
//
// The server renders the reader section (stored extracted_text) and the
// initial note/tags; JS drives the markdown preview and the explicit Save.
// There is deliberately NO autosave: changes persist only on the Save button
// or Ctrl/Cmd+S.

function initDetailPage() {
  const root = $("#detail");
  const bookmarkId = Number(root.dataset.id);
  const titleInput = $("#title");
  const isReadInput = $("#is-read");
  const noteTextarea = $("#note");
  const notePreview = $("#note-preview");
  const tagInput = $("#tag-input");
  const tagChips = $("#tag-chips");
  const saveBtn = $("#save");
  const saveStatus = $("#save-status");

  // --- Unsaved-edit guard: any change sets a dirty flag; beforeunload
  //     warns before the edits are lost on navigation. Cleared on save. ---

  let dirty = false;

  function markDirty() {
    dirty = true;
  }

  function clearDirty() {
    dirty = false;
  }

  window.addEventListener("beforeunload", (e) => {
    if (!dirty) return;
    e.preventDefault();
    e.returnValue = "";
  });

  // --- Tags editor: chips + input. Enter/comma adds a chip, × removes one. ---

  function addTag(name) {
    name = name.trim().toLowerCase();
    if (!name) return;
    if ($(`.chip-tag[data-tag="${CSS.escape(name)}"]`, tagChips)) return;
    const chip = document.createElement("span");
    chip.className = "tag chip-tag";
    chip.dataset.tag = name;
    chip.appendChild(document.createTextNode(name + " "));
    const remove = document.createElement("button");
    remove.type = "button";
    remove.className = "chip-remove";
    remove.setAttribute("aria-label", "Remove tag " + name);
    remove.textContent = "×";
    remove.addEventListener("click", () => {
      chip.remove();
      markDirty();
    });
    chip.appendChild(remove);
    tagChips.appendChild(chip);
    markDirty();
  }

  function currentTags() {
    return $$(".chip-tag", tagChips).map((c) => c.dataset.tag);
  }

  tagInput.addEventListener("keydown", (e) => {
    if (e.key === "Enter" || e.key === ",") {
      e.preventDefault();
      addTag(tagInput.value);
      tagInput.value = "";
    }
  });
  tagInput.addEventListener("blur", () => {
    if (tagInput.value.trim()) {
      addTag(tagInput.value);
      tagInput.value = "";
    }
  });

  titleInput.addEventListener("input", markDirty);
  isReadInput.addEventListener("change", markDirty);

  // --- Markdown preview via the vendored marked.js (Edit / Preview tabs).
  // Rendered LIVE (debounced) as the user types, so the Preview tab always
  // shows current content. ---

  const tabWrite = $("#tab-write");
  const tabPreview = $("#tab-preview");

  function renderPreview() {
    if (window.marked) {
      notePreview.innerHTML = window.marked.parse(noteTextarea.value || "");
    }
  }

  const renderPreviewDebounced = debounce(renderPreview, 180);

  function showTab(which) {
    const isPreview = which === "preview";
    tabWrite.classList.toggle("active", !isPreview);
    tabPreview.classList.toggle("active", isPreview);
    tabWrite.setAttribute("aria-selected", String(!isPreview));
    tabPreview.setAttribute("aria-selected", String(isPreview));
    noteTextarea.hidden = isPreview;
    notePreview.hidden = !isPreview;
    if (isPreview) renderPreview();
  }

  tabWrite.addEventListener("click", () => showTab("write"));
  tabPreview.addEventListener("click", () => showTab("preview"));

  // --- Wikilink autocomplete: typing [[ opens a dropdown of bookmarks.
  // GET /api/autocomplete?q= matches title/url (prefix+substring, capped at
  // 10). Selecting inserts [[Title|]] at the cursor, replacing the [[query.
  // Arrow keys move the selection; Enter/Tab or a click commits; Escape
  // closes. ---

  const acEl = document.createElement("div");
  acEl.id = "wikilink-autocomplete";
  acEl.className = "ac-dropdown";
  acEl.setAttribute("role", "listbox");
  acEl.hidden = true;
  acEl.addEventListener("mousedown", (e) => e.preventDefault());
  acEl.addEventListener("click", (e) => {
    const itemEl = e.target.closest(".ac-item");
    if (itemEl) insertAutocomplete(itemEl.dataset.title || itemEl.dataset.url);
  });
  document.body.appendChild(acEl);

  let acItems = [];
  let acSelected = -1;
  let acQuery = null;
  let acLoading = false;
  let acFetchSeq = 0;

  function openBracketContext() {
    const value = noteTextarea.value;
    const caret = noteTextarea.selectionStart ?? value.length;
    const before = value.slice(0, caret);
    const lastOpen = before.lastIndexOf("[[");
    if (lastOpen === -1) return null;
    if (before.slice(lastOpen + 2).includes("]]")) return null;
    return { start: lastOpen, query: before.slice(lastOpen + 2) };
  }

  function positionAutocomplete() {
    const rect = noteTextarea.getBoundingClientRect();
    if (rect.width === 0) return;
    const value = noteTextarea.value;
    const caret = noteTextarea.selectionStart ?? value.length;
    const style = getComputedStyle(noteTextarea);
    const lineHeight = parseFloat(style.lineHeight) || 21;
    const padTop = parseFloat(style.paddingTop) || 0;
    const lineCount = value.slice(0, caret).split("\n").length;
    const top = rect.top + padTop + (lineCount - 1) * lineHeight + 2;
    acEl.style.left = `${rect.left + 12}px`;
    acEl.style.width = `${Math.max(240, rect.width - 24)}px`;
    acEl.style.top = `${Math.min(top, window.innerHeight - 260)}px`;
  }

  function renderAutocomplete() {
    const ctx = openBracketContext();
    if (!ctx || noteTextarea.hidden) {
      closeAutocomplete();
      return;
    }
    positionAutocomplete();
    if (acItems.length > 0) {
      acSelected = Math.max(0, Math.min(acSelected, acItems.length - 1));
      acEl.innerHTML = acItems
        .map(
          (item, i) => `
          <button type="button" role="option" aria-selected="${i === acSelected}"
                  class="ac-item${i === acSelected ? " selected" : ""}"
                  data-title="${escapeHtml(item.title)}" data-url="${escapeHtml(item.url)}">
            <span class="ac-title">${escapeHtml(item.title || item.url)}</span>
            ${item.title ? `<span class="ac-url">${escapeHtml(item.url)}</span>` : ""}
          </button>`
        )
        .join("");
    } else if (ctx.query.trim() === "") {
      acEl.innerHTML = '<div class="ac-hint">Start typing a title or URL…</div>';
    } else if (acLoading) {
      acEl.innerHTML = '<div class="ac-hint">Searching…</div>';
    } else {
      acEl.innerHTML = '<div class="ac-hint">No matches</div>';
    }
    acEl.hidden = false;
  }

  function closeAutocomplete() {
    acEl.hidden = true;
    acEl.innerHTML = "";
    acItems = [];
    acSelected = -1;
    acQuery = null;
    acLoading = false;
    acFetchSeq++;
  }

  async function fetchAutocomplete(query) {
    const seq = ++acFetchSeq;
    let items = [];
    try {
      const resp = await fetch("/api/autocomplete?q=" + encodeURIComponent(query));
      if (!resp.ok) throw new Error("autocomplete failed: " + resp.status);
      items = await resp.json();
    } catch (err) {
      console.error(err);
      items = [];
    }
    if (seq !== acFetchSeq) return;
    acQuery = query;
    acLoading = false;
    acItems = items;
    acSelected = -1;
    renderAutocomplete();
  }

  const acDebounced = debounce(() => {
    const ctx = openBracketContext();
    if (ctx) fetchAutocomplete(ctx.query);
  }, 180);

  function updateAutocomplete() {
    if (noteTextarea.hidden) {
      closeAutocomplete();
      return;
    }
    const ctx = openBracketContext();
    if (!ctx) {
      closeAutocomplete();
      return;
    }
    positionAutocomplete();
    if (ctx.query !== acQuery) {
      acItems = [];
      acSelected = -1;
      acLoading = true;
    }
    renderAutocomplete();
    acDebounced();
  }

  function insertAutocomplete(title) {
    const ctx = openBracketContext();
    if (!ctx || !title) return;
    const value = noteTextarea.value;
    const caret = noteTextarea.selectionStart ?? value.length;
    const insertion = `[[${title}|]]`;
    noteTextarea.value = value.slice(0, ctx.start) + insertion + value.slice(caret);
    const newCaret = ctx.start + insertion.length;
    noteTextarea.setSelectionRange(newCaret, newCaret);
    closeAutocomplete();
    renderPreviewDebounced();
    markDirty();
  }

  noteTextarea.addEventListener("input", () => {
    markDirty();
    renderPreviewDebounced();
    updateAutocomplete();
  });
  noteTextarea.addEventListener("keydown", (e) => {
    if (acEl.hidden) return;
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      if (acItems.length === 0) return;
      const delta = e.key === "ArrowDown" ? 1 : -1;
      acSelected = (acSelected + delta + acItems.length) % acItems.length;
      renderAutocomplete();
    } else if (e.key === "Enter" || e.key === "Tab") {
      if (acItems.length > 0) {
        e.preventDefault();
        const item = acItems[acSelected >= 0 ? acSelected : 0];
        insertAutocomplete(item.title || item.url);
      }
    } else if (e.key === "Escape") {
      e.preventDefault();
      closeAutocomplete();
    }
  });
  noteTextarea.addEventListener("blur", closeAutocomplete);
  document.addEventListener("click", (e) => {
    if (acEl.hidden || acEl.contains(e.target) || e.target === noteTextarea) return;
    closeAutocomplete();
  });

  // --- Explicit save only (button + Ctrl/Cmd+S). Never autosave. ---

  function setStatus(text, isError = false) {
    saveStatus.textContent = text;
    saveStatus.classList.toggle("error", isError);
  }

  async function save() {
    saveBtn.disabled = true;
    setStatus("Saving…");
    const payload = {
      note_body: noteTextarea.value,
      title: titleInput.value.trim(),
      tags: currentTags(),
      is_read: isReadInput.checked ? 1 : 0,
    };
    try {
      const resp = await fetch(`/api/bookmarks/${bookmarkId}`, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken(),
        },
        body: JSON.stringify(payload),
      });
      if (!resp.ok) {
        const detail = await resp.json().catch(() => ({}));
        throw new Error(detail.detail || "Save failed (" + resp.status + ")");
      }
      setStatus("Saved");
      clearDirty();
    } catch (err) {
      setStatus(err.message, true);
    } finally {
      saveBtn.disabled = false;
    }
  }

  saveBtn.addEventListener("click", save);
  document.addEventListener("keydown", (e) => {
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "s") {
      e.preventDefault();
      save();
    }
  });

  // --- Backlinks panel (todo 21): GET /api/bookmarks/{id}/backlinks and
  // render Linked mentions (clickable → the source bookmark) and Unlinked
  // mentions (context snippet + a "Link" button). The Link button rewrites
  // the prose mention into [[Title]] in the SOURCE bookmark via PATCH, then
  // re-fetches so the mention moves unlinked → linked. There is deliberately
  // NO auto-link: nothing is written until the user clicks Link. ---

  const backlinksPanel = $("#backlinks-panel");
  const backlinksEl = $("#backlinks");
  // The server-known title at page load — the wikilink target the Link
  // button must resolve against, even if the user has unsaved title edits.
  const targetTitle = (backlinksPanel.dataset.targetTitle || "").trim();

  function backlinkRowHtml(item, linked) {
    const line = item.line_number
      ? `<span class="bl-line">line ${item.line_number}</span>`
      : "";
    const snippet = `<span class="bl-snippet">${escapeHtml(item.snippet)}</span>`;
    if (linked) {
      return `
        <li class="bl-row bl-linked">
          <a class="bl-source" href="/bookmark/${item.source_id}">${escapeHtml(item.source_title)}</a>
          ${line}${snippet}
        </li>`;
    }
    return `
      <li class="bl-row bl-unlinked" data-source-id="${item.source_id}">
        <span class="bl-source">${escapeHtml(item.source_title)}</span>
        ${line}${snippet}
        <button type="button" class="btn bl-link" data-source-id="${item.source_id}">Link</button>
      </li>`;
  }

  function renderBacklinks(data) {
    const linked = data.linked || [];
    const unlinked = data.unlinked || [];
    if (linked.length === 0 && unlinked.length === 0) {
      backlinksEl.innerHTML =
        '<p class="bl-empty">No backlinks yet. When another bookmark\u2019s note mentions this one, it will appear here.</p>';
      return;
    }
    const linkedSection = linked.length
      ? `<div class="bl-section"><h3 class="bl-heading">Linked mentions <span class="bl-count">${linked.length}</span></h3><ul class="bl-list">${linked.map((i) => backlinkRowHtml(i, true)).join("")}</ul></div>`
      : "";
    const unlinkedSection = unlinked.length
      ? `<div class="bl-section"><h3 class="bl-heading">Unlinked mentions <span class="bl-count">${unlinked.length}</span></h3><ul class="bl-list">${unlinked.map((i) => backlinkRowHtml(i, false)).join("")}</ul></div>`
      : "";
    backlinksEl.innerHTML = linkedSection + unlinkedSection;
  }

  async function refreshBacklinks() {
    try {
      const resp = await fetch(`/api/bookmarks/${bookmarkId}/backlinks`);
      if (!resp.ok) throw new Error("backlinks failed: " + resp.status);
      renderBacklinks(await resp.json());
    } catch (err) {
      console.error(err);
      backlinksEl.innerHTML =
        '<p class="bl-empty">Could not load backlinks.</p>';
    }
  }

  backlinksEl.addEventListener("click", async (e) => {
    const btn = e.target.closest(".bl-link");
    if (!btn) return;
    const sourceId = Number(btn.dataset.sourceId);
    btn.disabled = true;
    const label = btn.textContent;
    btn.textContent = "Linking…";
    try {
      // Pull the source's current note and rewrite the FIRST occurrence of
      // the target title into [[Title]] (mirrors links.py _line_of, which is
      // what made the source an unlinked mention).
      const resp = await fetch(`/api/bookmarks/${sourceId}`);
      if (!resp.ok) throw new Error("Could not load the source note (" + resp.status + ")");
      const source = await resp.json();
      const noteBody = source.note_body || "";
      const idx = noteBody.toLowerCase().indexOf(targetTitle.toLowerCase());
      if (idx === -1) throw new Error("Mention no longer present in the source note");
      const rewritten =
        noteBody.slice(0, idx) + `[[${targetTitle}]]` + noteBody.slice(idx + targetTitle.length);
      const patch = await fetch(`/api/bookmarks/${sourceId}`, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken(),
        },
        body: JSON.stringify({ note_body: rewritten }),
      });
      if (!patch.ok) {
        const detail = await patch.json().catch(() => ({}));
        throw new Error(detail.detail || "Link failed (" + patch.status + ")");
      }
      await refreshBacklinks();
    } catch (err) {
      // Show the failure inline rather than console.error — the QA scenario
      // asserts zero console errors on the backlinks panel.
      btn.disabled = false;
      btn.textContent = label;
      const row = btn.closest(".bl-row");
      if (row) {
        const msg = document.createElement("span");
        msg.className = "bl-error";
        msg.textContent = err.message || "Link failed";
        row.appendChild(msg);
      }
    }
  });

  refreshBacklinks();
}

// ---------------------------------------------------------------------------
// Graph page (/graph) — neighborhood graph via the vendored Cytoscape.js
// ---------------------------------------------------------------------------
//
// The seed's 1-2 hop neighborhood over the links table is fetched from
// /api/graph?seed={id}&depth={1|2} (the API never returns the whole corpus)
// and rendered with the vendored Cytoscape.js browser global. Node size ∝
// indegree (how many bookmarks across the corpus point at the node). Filters
// (tag / is:unread / orphan) are applied client-side to the fetched
// neighborhood; the SEED node is always rendered as the graph's anchor.
// Clicking a node navigates to its detail page. Without a seed the page shows
// a picker over /api/search. The graph is a view — the grid stays primary.

function initGraphPage() {
  const root = $("#graph");
  const canvas = $("#graph-canvas");
  const empty = $("#graph-empty");
  const seedPicker = $("#graph-seed-picker");
  const depthSelect = $("#graph-depth");
  const tagFilter = $("#graph-tag-filter");
  const unreadFilter = $("#graph-unread-filter");
  const orphanFilter = $("#graph-orphan-filter");
  const stats = $("#graph-stats");

  const seedId = root.dataset.seed ? Number(root.dataset.seed) : null;
  let graphData = { nodes: [], edges: [] };
  let cy = null;

  function nodeSize(indegree) {
    return Math.min(46, Math.max(14, 14 + Math.sqrt(Math.max(indegree, 0)) * 9));
  }

  function showEmpty(message, opts = {}) {
    empty.textContent = message;
    empty.classList.toggle("blocking", !!opts.blocking);
    empty.hidden = false;
    if (opts.blocking) canvas.hidden = true;
  }

  function hideEmpty() {
    empty.hidden = true;
    empty.classList.remove("blocking");
    canvas.hidden = false;
  }

  // Client-side filters. Orphan = a node with NO edges among the currently
  // visible node set (degree 0), e.g. an isolated bookmark. The seed node is
  // always kept — it is the anchor of the view.
  function visibleSubgraph() {
    const tag = tagFilter.value;
    const unreadOnly = unreadFilter.checked;
    const orphanOnly = orphanFilter.checked;
    const keptIds = new Set();
    const nodes = graphData.nodes.filter((n) => {
      if (n.id !== seedId) {
        if (tag && !(n.tags || []).includes(tag)) return false;
        if (unreadOnly && n.is_read) return false;
      }
      keptIds.add(n.id);
      return true;
    });
    const edges = graphData.edges.filter(
      (e) => keptIds.has(e.source) && keptIds.has(e.target)
    );
    if (orphanOnly) {
      const degree = new Map();
      for (const e of edges) {
        degree.set(e.source, (degree.get(e.source) || 0) + 1);
        degree.set(e.target, (degree.get(e.target) || 0) + 1);
      }
      return {
        nodes: nodes.filter((n) => (degree.get(n.id) || 0) === 0),
        edges,
      };
    }
    return { nodes, edges };
  }

  function renderGraph() {
    if (!window.cytoscape) {
      showEmpty("The graph engine failed to load.");
      return;
    }
    const { nodes, edges } = visibleSubgraph();
    if (nodes.length === 0) {
      if (cy) {
        cy.destroy();
        cy = null;
      }
      showEmpty("No nodes match the current filters.", { blocking: true });
      return;
    }

    const byId = new Map(graphData.nodes.map((n) => [n.id, n]));
    const elements = nodes.map((n) => ({
      data: {
        id: String(n.id),
        label: n.title || n.url,
        isSeed: n.id === seedId,
        isRead: !!n.is_read,
        indegree: n.indegree,
      },
      classes: (n.id === seedId ? "seed " : "") + (n.is_read ? "read" : "unread"),
    }));
    for (const e of edges) {
      elements.push({
        data: { id: `${e.source}-${e.target}`, source: String(e.source), target: String(e.target) },
      });
    }

    if (cy) cy.destroy();
    cy = window.cytoscape({
      container: canvas,
      elements,
      style: [
        {
          selector: "node",
          style: {
            label: "data(label)",
            "font-size": 11,
            color: "var(--fg)",
            "text-wrap": "wrap",
            "text-max-width": "120px",
            "text-valign": "bottom",
            "text-halign": "center",
            "text-margin-y": 4,
            "background-color": "var(--bg-elev)",
            "border-width": 1.5,
            "border-color": "var(--border)",
            "overlay-opacity": 0,
          },
        },
        { selector: "node.seed", style: { "border-width": 3, "border-color": "var(--accent)" } },
        { selector: "node.unread", style: { "background-color": "var(--accent-soft)" } },
        {
          selector: "edge",
          style: {
            width: 1.5,
            "line-color": "var(--fg-muted)",
            "target-arrow-color": "var(--fg-muted)",
            "target-arrow-shape": "triangle",
            "arrow-scale": 0.8,
            "curve-style": "bezier",
            "overlay-opacity": 0,
          },
        },
      ],
      layout: { name: "cose", animate: false, nodeRepulsion: 8000 },
    });
    cy.nodes().forEach((n) => {
      const size = nodeSize(byId.get(Number(n.id())).indegree);
      n.style({ width: size, height: size });
    });
    cy.on("tap", "node", (evt) => {
      window.location.href = `/bookmark/${evt.target.id()}`;
    });
    // The e2e seam: tests read node positions / rendered state through this.
    window.cy = cy;

    canvas.dataset.rendered = "true";
    stats.textContent = `${nodes.length} node${nodes.length === 1 ? "" : "s"} · ${edges.length} edge${edges.length === 1 ? "" : "s"}`;
    // A one-node/zero-edge neighborhood keeps the node rendered and shows the
    // empty-state message as a transparent overlay on top of it.
    if (graphData.nodes.length === 1 && graphData.edges.length === 0) {
      showEmpty(
        "This bookmark isn't linked to anything yet. Add [[wikilinks]] to other bookmarks in its note to see them here."
      );
    } else {
      hideEmpty();
    }
  }

  function populateTagFilter(nodes) {
    const seen = new Set();
    for (const n of nodes) for (const t of n.tags || []) seen.add(t);
    const current = tagFilter.value;
    tagFilter.innerHTML = '<option value="">all</option>';
    for (const t of [...seen].sort()) {
      const opt = document.createElement("option");
      opt.value = t;
      opt.textContent = t;
      tagFilter.appendChild(opt);
    }
    if ([...seen].includes(current)) tagFilter.value = current;
  }

  async function loadGraph(seed, depth) {
    canvas.dataset.rendered = "false";
    seedPicker.hidden = true;
    try {
      const resp = await fetch(`/api/graph?seed=${seed}&depth=${depth}`);
      if (!resp.ok) {
        showEmpty("Could not load the graph (" + resp.status + ").");
        return;
      }
      graphData = await resp.json();
      populateTagFilter(graphData.nodes);
      renderGraph();
    } catch (err) {
      console.error(err);
      showEmpty("Could not load the graph.");
    }
  }

  function currentSeed() {
    return root.dataset.seed ? Number(root.dataset.seed) : null;
  }

  if (!seedId) {
    // Seed picker: search /api/search, click a result to open its graph.
    canvas.hidden = true;
    seedPicker.hidden = false;
    const searchInput = $("#graph-seed-search");
    const resultsEl = $("#graph-seed-results");
    const debouncedSearch = debounce(async () => {
      const q = searchInput.value.trim();
      resultsEl.innerHTML = "";
      if (!q) return;
      try {
        const resp = await fetch("/api/search?q=" + encodeURIComponent(q) + "&limit=8");
        if (!resp.ok) return;
        const data = await resp.json();
        resultsEl.innerHTML = data.items
          .map(
            (b) => `<li><button type="button" class="graph-seed-result" data-id="${b.id}">
              <span class="qs-title">${escapeHtml(b.title || b.url)}</span>
              <span class="qs-url">${escapeHtml(b.url)}</span>
            </button></li>`
          )
          .join("");
      } catch (err) {
        console.error(err);
      }
    }, 180);
    searchInput.addEventListener("input", debouncedSearch);
    resultsEl.addEventListener("click", (e) => {
      const btn = e.target.closest(".graph-seed-result");
      if (btn) window.location.href = `/graph?seed=${btn.dataset.id}`;
    });
  } else {
    const initialDepth = Number(root.dataset.depth) || 1;
    depthSelect.value = String(initialDepth);
    depthSelect.addEventListener("change", () => {
      const depth = Number(depthSelect.value);
      loadGraph(currentSeed(), depth);
    });
    tagFilter.addEventListener("change", renderGraph);
    unreadFilter.addEventListener("change", renderGraph);
    orphanFilter.addEventListener("change", renderGraph);
    loadGraph(seedId, initialDepth);
  }
}

// ---------------------------------------------------------------------------
// Dedup review page (/dedup) — candidate groups with keep-one radio + merge
// action, plus the undo control. Reads GET /api/dedup/candidates; mutations
// go through POST /api/dedup/merge and DELETE /api/dedup/undo (CSRF-checked).
// ---------------------------------------------------------------------------

function initDedupPage() {
  const root = $("#dedup");
  const groupsEl = $("#dedup-groups");
  const statusEl = $("#dedup-status");
  const undoBtn = $("#dedup-undo");

  function setStatus(text, isError = false) {
    statusEl.textContent = text;
    statusEl.classList.toggle("dedup-error", isError);
  }

  function rowHtml(entry, isCanonical) {
    return `
      <li class="dedup-row">
        <label class="dedup-keep">
          <input type="radio" name="keep-${entry.id}" value="${entry.id}"
            ${isCanonical ? "checked" : ""}>
          <span class="dedup-badge ${isCanonical ? "dedup-canonical" : ""}">${isCanonical ? "keep (oldest)" : "merge"}</span>
        </label>
        <div class="dedup-row-body">
          <div class="dedup-row-title">${escapeHtml(entry.title || entry.url)}</div>
          <a class="dedup-row-url" href="${escapeHtml(entry.url)}" target="_blank" rel="noopener noreferrer">${escapeHtml(entry.url)}</a>
        </div>
        <span class="dedup-reason">${escapeHtml(entry.reason || "")}</span>
      </li>`;
  }

  function renderGroup(group) {
    const section = document.createElement("section");
    section.className = "dedup-group";
    const rows = [group.canonical, ...group.members];
    section.innerHTML = `
      <div class="dedup-group-head">
        <span class="dedup-count">${group.count} bookmarks</span>
        <button type="button" class="btn dedup-merge">Merge into selected</button>
      </div>
      <ul class="dedup-rows">
        ${rowHtml(group.canonical, true)}
        ${group.members.map((m) => rowHtml(m, false)).join("")}
      </ul>
      <p class="dedup-hint">The oldest bookmark is pre-selected. Merging combines
        tags, notes and links into the kept row (its note wins on conflict); the
        merge can be undone.</p>`;
    section.querySelector(".dedup-merge").addEventListener("click", () => mergeGroup(section));
    return section;
  }

  async function loadGroups() {
    groupsEl.innerHTML = "";
    try {
      const resp = await fetch("/api/dedup/candidates");
      if (!resp.ok) { setStatus("Could not load candidates.", true); return; }
      const { groups } = await resp.json();
      if (!groups.length) {
        groupsEl.innerHTML = `<p class="dedup-empty">No duplicate candidates found.</p>`;
        return;
      }
      for (const group of groups) groupsEl.appendChild(renderGroup(group));
    } catch (err) {
      setStatus("Could not load candidates: " + err.message, true);
    }
  }

  async function mergeGroup(section) {
    const checked = section.querySelector('input[type="radio"]:checked');
    if (!checked) return;
    const keepId = Number(checked.value);
    const mergeIds = $$('input[type="radio"]', section)
      .map((radio) => Number(radio.value))
      .filter((id) => id !== keepId);
    const btn = section.querySelector(".dedup-merge");
    btn.disabled = true;
    btn.textContent = "Merging…";
    try {
      const resp = await fetch("/api/dedup/merge", {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken() },
        body: JSON.stringify({ keep_id: keepId, merge_ids: mergeIds }),
      });
      if (!resp.ok) {
        const detail = await resp.json().catch(() => ({}));
        setStatus("Merge failed: " + (detail.detail || resp.status), true);
        btn.disabled = false;
        btn.textContent = "Merge into selected";
        return;
      }
      setStatus(`Merged ${mergeIds.length} bookmark(s) into #${keepId}.`);
      await loadGroups();
    } catch (err) {
      setStatus("Merge failed: " + err.message, true);
      btn.disabled = false;
      btn.textContent = "Merge into selected";
    }
  }

  async function undoLastMerge() {
    undoBtn.disabled = true;
    try {
      const resp = await fetch("/api/dedup/undo", {
        method: "DELETE",
        headers: { "X-CSRF-Token": csrfToken() },
      });
      if (resp.status === 404) {
        setStatus("Nothing to undo.", true);
        return;
      }
      if (!resp.ok) { setStatus("Undo failed (" + resp.status + ").", true); return; }
      const data = await resp.json();
      setStatus(`Restored bookmark(s) ${data.restored.join(", ")} from the last merge.`);
      await loadGroups();
    } catch (err) {
      setStatus("Undo failed: " + err.message, true);
    } finally {
      undoBtn.disabled = false;
    }
  }

  undoBtn.addEventListener("click", undoLastMerge);
  loadGroups();
}

// ---------------------------------------------------------------------------
// Tag cleanup page (/tags-cleanup) — suggested consolidation pairs (case +
// fuzzy + junk) with apply buttons, plus the proliferation stats. Reads GET
// /api/tags/consolidation-candidates; mutations go through POST /api/tags/merge,
// POST /api/tags/{id} (rename) and DELETE /api/tags/{id} (empty tags only),
// all CSRF-checked. Never applies anything automatically.
// ---------------------------------------------------------------------------

function initTagsCleanupPage() {
  const statusEl = $("#tc-status");
  const statsEl = $("#tc-stats");
  const caseEl = $("#tc-case");
  const fuzzyEl = $("#tc-fuzzy");
  const junkEl = $("#tc-junk");

  function setStatus(text, isError = false) {
    statusEl.textContent = text;
    statusEl.classList.toggle("dedup-error", isError);
  }

  async function applyMerge(btn, fromName, toName) {
    btn.disabled = true;
    const label = btn.textContent;
    btn.textContent = "Merging…";
    try {
      const resp = await fetch("/api/tags/merge", {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken() },
        body: JSON.stringify({ from: fromName, to: toName }),
      });
      if (!resp.ok) {
        const detail = await resp.json().catch(() => ({}));
        throw new Error(detail.detail || "Merge failed (" + resp.status + ")");
      }
      const data = await resp.json();
      setStatus(`Merged "${data.from}" → "${data.to}" (${data.bookmarks_affected} bookmark link(s)).`);
      await load();
    } catch (err) {
      setStatus(err.message, true);
      btn.disabled = false;
      btn.textContent = label;
    }
  }

  async function renameTag(form, tagId) {
    const input = form.querySelector(".tc-rename-input");
    const name = input.value.trim();
    const btn = form.querySelector(".tc-rename");
    if (!name) return;
    btn.disabled = true;
    const label = btn.textContent;
    btn.textContent = "Renaming…";
    try {
      const resp = await fetch(`/api/tags/${tagId}`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken() },
        body: JSON.stringify({ name }),
      });
      if (!resp.ok) {
        const detail = await resp.json().catch(() => ({}));
        throw new Error(detail.detail || "Rename failed (" + resp.status + ")");
      }
      setStatus(`Renamed tag to "${resp.json().name}".`);
      await load();
    } catch (err) {
      setStatus(err.message, true);
      btn.disabled = false;
      btn.textContent = label;
    }
  }

  async function deleteTag(btn, tagId) {
    btn.disabled = true;
    const label = btn.textContent;
    btn.textContent = "Deleting…";
    try {
      const resp = await fetch(`/api/tags/${tagId}`, {
        method: "DELETE",
        headers: { "X-CSRF-Token": csrfToken() },
      });
      if (!resp.ok) {
        const detail = await resp.json().catch(() => ({}));
        throw new Error(detail.detail || "Delete failed (" + resp.status + ")");
      }
      setStatus("Deleted empty tag.");
      await load();
    } catch (err) {
      setStatus(err.message, true);
      btn.disabled = false;
      btn.textContent = label;
    }
  }

  function pairRow(pair) {
    const score = pair.score !== undefined ? `<span class="tc-score">${pair.score}%</span>` : "";
    return `
      <li class="tc-pair">
        <span class="tc-names"><code>${escapeHtml(pair.from)}</code> → <code>${escapeHtml(pair.to)}</code></span>
        ${score}
        <span class="tc-count">${pair.from_count} → ${pair.to_count} bookmark(s)</span>
        <button type="button" class="btn tc-apply" data-from="${escapeHtml(pair.from)}" data-to="${escapeHtml(pair.to)}">Merge</button>
      </li>`;
  }

  function renderPairs(section, pairs, emptyText) {
    const title = section.dataset.title;
    section.innerHTML = `<h3 class="tc-heading">${escapeHtml(title)}</h3>`;
    if (!pairs.length) {
      section.innerHTML += `<p class="dedup-empty">${escapeHtml(emptyText)}</p>`;
      return;
    }
    section.innerHTML += `<ul class="tc-pairs">${pairs.map(pairRow).join("")}</ul>`;
    section.querySelectorAll(".tc-apply").forEach((btn) => {
      btn.addEventListener("click", () => applyMerge(btn, btn.dataset.from, btn.dataset.to));
    });
  }

  function renderJunk(junkTags) {
    junkEl.innerHTML = `<h3 class="tc-heading">Junk tags</h3>`;
    if (!junkTags.length) {
      junkEl.innerHTML += `<p class="dedup-empty">No junk tags found.</p>`;
      return;
    }
    junkEl.innerHTML += `
      <ul class="tc-pairs">${junkTags.map((j) => `
        <li class="tc-pair tc-junk" data-id="${j.id}">
          <span class="tc-names"><code>${escapeHtml(j.name)}</code></span>
          <span class="tc-count">${j.n} bookmark(s)</span>
          <form class="tc-rename-form">
            <input class="tc-rename-input" type="text" value="${escapeHtml(j.name)}" aria-label="New name for ${escapeHtml(j.name)}">
            <button type="submit" class="btn tc-rename">Rename</button>
          </form>
          <button type="button" class="btn tc-delete" data-id="${j.id}">Delete</button>
        </li>`).join("")}
      </ul>`;
    junkEl.querySelectorAll(".tc-rename-form").forEach((form) => {
      form.addEventListener("submit", (e) => {
        e.preventDefault();
        renameTag(form, form.closest(".tc-junk").dataset.id);
      });
    });
    junkEl.querySelectorAll(".tc-delete").forEach((btn) => {
      btn.addEventListener("click", () => deleteTag(btn, btn.dataset.id));
    });
  }

  async function load() {
    try {
      const resp = await fetch("/api/tags/consolidation-candidates");
      if (!resp.ok) { setStatus("Could not load candidates.", true); return; }
      const data = await resp.json();
      const prol = data.proliferation;
      statsEl.innerHTML = `
        <h3 class="tc-heading">Tag proliferation</h3>
        <p class="tc-stats-text">${prol.count} tags total · ${prol.tags_on_le_3} tags on ≤ 3 bookmarks
          (the long tail most worth consolidating).</p>`;
      renderPairs(caseEl, data.case_pairs, "No case duplicates found.");
      renderPairs(fuzzyEl, data.fuzzy_pairs, "No similar-name pairs found.");
      renderJunk(data.junk_tags);
    } catch (err) {
      setStatus("Could not load candidates: " + err.message, true);
    }
  }

  load();
}

// ---------------------------------------------------------------------------
// AI tagging page (/tags-suggestions) — per-bookmark candidate tags from the
// user's existing taxonomy with approve/discard buttons and an apply-selected
// action. Reads GET /api/tags/{tag}/suggestions (already vocabulary- and
// stopword-filtered server-side); applying goes through POST /api/tags/apply
// (CSRF-checked) — one request per approved bookmark so each bookmark gets
// exactly its own candidate tags. Never applies anything automatically.
// ---------------------------------------------------------------------------

function initTagSuggestionsPage() {
  const statusEl = $("#ts-status");
  const tagSelect = $("#ts-tag");
  const loadBtn = $("#ts-load");
  const listEl = $("#ts-list");
  const summaryEl = $("#ts-summary");
  let suggestions = [];   // current [{bookmark_id, title, url, candidate_tags}]
  const approved = new Map(); // bookmark_id -> {title, tags}

  function setStatus(text, isError = false) {
    statusEl.textContent = text;
    statusEl.classList.toggle("dedup-error", isError);
  }

  function updateSummary() {
    const n = approved.size;
    summaryEl.hidden = n === 0;
    summaryEl.innerHTML = n
      ? `${n} approved · <button id="ts-apply" class="btn ts-apply" type="button">Apply selected</button>`
      : "";
    if (n) {
      $("#ts-apply").addEventListener("click", applySelected);
    }
  }

  async function loadTags() {
    const resp = await fetch("/api/tags");
    if (!resp.ok) { setStatus("Could not load tags.", true); return; }
    const data = await resp.json();
    tagSelect.innerHTML = data.tags
      .map((t) => `<option value="${escapeHtml(t.name)}">${escapeHtml(t.name)} (${t.n})</option>`)
      .join("");
    if (data.tags.length) loadSuggestions();
  }

  function renderRows() {
    if (!suggestions.length) {
      listEl.innerHTML = `<p class="dedup-empty">No suggestions to review — the LLM returned nothing in-vocabulary for this bucket.</p>`;
      return;
    }
    listEl.innerHTML = suggestions.map((s, i) => `
      <li class="ts-row" data-index="${i}">
        <div class="ts-row-head">
          <span class="ts-row-title">${escapeHtml(s.title || s.url)}</span>
          <a class="ts-row-url" href="${escapeHtml(s.url)}" target="_blank" rel="noopener noreferrer">${escapeHtml(s.url)}</a>
        </div>
        <div class="ts-chips">
          ${s.candidate_tags.length
            ? s.candidate_tags.map((t) => `<span class="tag">${escapeHtml(t)}</span>`).join("")
            : `<span class="ts-none">no in-vocabulary tags</span>`}
        </div>
        <div class="ts-actions">
          <button type="button" class="btn ts-approve" ${s.candidate_tags.length ? "" : "disabled"}>Approve</button>
          <button type="button" class="btn ts-discard">Discard</button>
        </div>
      </li>`).join("");
    listEl.querySelectorAll(".ts-approve").forEach((btn, i) => {
      btn.addEventListener("click", () => approve(i, btn));
    });
    listEl.querySelectorAll(".ts-discard").forEach((btn, i) => {
      btn.addEventListener("click", () => discard(i, btn));
    });
  }

  function approve(index, btn) {
    const s = suggestions[index];
    approved.set(s.bookmark_id, { title: s.title || s.url, tags: s.candidate_tags });
    btn.closest(".ts-row").classList.add("ts-approved");
    btn.disabled = true;
    setStatus(`Approved tags for “${approved.get(s.bookmark_id).title}”.`);
    updateSummary();
  }

  function discard(index, btn) {
    const s = suggestions[index];
    approved.delete(s.bookmark_id);
    btn.closest(".ts-row").classList.add("ts-discarded");
    btn.closest(".ts-row").querySelector(".ts-approve").disabled = true;
    setStatus(`Discarded “${s.title || s.url}”.`);
    updateSummary();
  }

  async function loadSuggestions() {
    const tag = tagSelect.value;
    if (!tag) return;
    approved.clear();
    updateSummary();
    loadBtn.disabled = true;
    setStatus(`Asking the LLM for suggestions in “${tag}”…`);
    try {
      const resp = await fetch(`/api/tags/${encodeURIComponent(tag)}/suggestions`);
      if (!resp.ok) {
        const detail = await resp.json().catch(() => ({}));
        setStatus(detail.detail || "Could not load suggestions (" + resp.status + ").", true);
        listEl.innerHTML = "";
        return;
      }
      suggestions = (await resp.json()).suggestions;
      renderRows();
      setStatus(suggestions.length ? "Review the suggestions below." : "No suggestions to review.");
    } catch (err) {
      setStatus("Could not load suggestions: " + err.message, true);
    } finally {
      loadBtn.disabled = false;
    }
  }

  async function applySelected() {
    loadBtn.disabled = true;
    const pending = Array.from(approved.entries());
    try {
      for (const [bookmarkId, s] of pending) {
        const resp = await fetch("/api/tags/apply", {
          method: "POST",
          headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken() },
          body: JSON.stringify({ bookmark_ids: [bookmarkId], tags: s.tags }),
        });
        if (!resp.ok) {
          const detail = await resp.json().catch(() => ({}));
          throw new Error(detail.detail || "Apply failed (" + resp.status + ")");
        }
      }
      setStatus(`Applied tags to ${pending.length} bookmark(s).`);
      approved.clear();
      updateSummary();
      await loadSuggestions();
    } catch (err) {
      setStatus(err.message, true);
    } finally {
      loadBtn.disabled = false;
    }
  }

  loadBtn.addEventListener("click", loadSuggestions);
  loadTags();
}

// ---------------------------------------------------------------------------
// Boot — run only the wiring for the page that exists.
// ---------------------------------------------------------------------------

if ($("#grid")) initGridPage();
if ($("#detail")) initDetailPage();
if ($("#graph")) initGraphPage();
if ($("#dedup")) initDedupPage();
if ($("#tags-cleanup")) initTagsCleanupPage();
if ($("#tags-suggestions")) initTagSuggestionsPage();
