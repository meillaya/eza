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

  // Add modal.
  $("#add-btn").addEventListener("click", () => {
    $("input[name=url]", modal).value = "";
    $("input[name=tags]", modal).value = "";
    modal.showModal();
    $("input[name=url]", modal).focus();
  });
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

  // Keyboard shortcut: "/" focuses search.
  document.addEventListener("keydown", (e) => {
    if (e.key === "/" && document.activeElement !== searchInput && !modal.open) {
      e.preventDefault();
      searchInput.focus();
    }
    if (e.key === "Escape" && modal.open) modal.close();
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
    remove.addEventListener("click", () => chip.remove());
    chip.appendChild(remove);
    tagChips.appendChild(chip);
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

  // --- Markdown preview via the vendored marked.js (Edit / Preview tabs). ---

  const tabWrite = $("#tab-write");
  const tabPreview = $("#tab-preview");

  function showTab(which) {
    const isPreview = which === "preview";
    tabWrite.classList.toggle("active", !isPreview);
    tabPreview.classList.toggle("active", isPreview);
    tabWrite.setAttribute("aria-selected", String(!isPreview));
    tabPreview.setAttribute("aria-selected", String(isPreview));
    noteTextarea.hidden = isPreview;
    notePreview.hidden = !isPreview;
    if (isPreview && window.marked) {
      notePreview.innerHTML = window.marked.parse(noteTextarea.value || "");
    }
  }

  tabWrite.addEventListener("click", () => showTab("write"));
  tabPreview.addEventListener("click", () => showTab("preview"));

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
}

// ---------------------------------------------------------------------------
// Boot — run only the wiring for the page that exists.
// ---------------------------------------------------------------------------

if ($("#grid")) initGridPage();
if ($("#detail")) initDetailPage();
