import { chromium } from "@playwright/test";

import { enterLibrary, newChecker } from "./lib/dom.mjs";

const BASE = process.env.EZA_BASE || "http://localhost:8084";
const browser = await chromium.launch({ headless: true });
const context = await browser.newContext();
const page = await context.newPage();
const { check, report } = newChecker();
const errors = [];
page.on("console", (m) => { if (m.type() === "error") errors.push(m.text()); });
page.on("pageerror", (e) => errors.push(String(e)));

// The harness claims one admin account and imports the mini fixture before
// this script runs, so the flow starts at the login page.
await enterLibrary(page);
console.log("session: ok");

async function api(path, options = {}) {
  return page.evaluate(async ({ path, options }) => {
    const csrf = document.cookie.split("; ").find((c) => c.startsWith("eza_csrf="))?.split("=")[1] || "";
    const headers = { ...(options.headers || {}) };
    if (options.method && options.method !== "GET") headers["X-CSRF-Token"] = csrf;
    const r = await fetch(path, { ...options, headers });
    const text = await r.text();
    let body = null;
    try { body = JSON.parse(text); } catch { body = text.slice(0, 160); }
    return { status: r.status, body, contentType: r.headers.get("content-type") };
  }, { path, options });
}

const seeded = await api("/api/v1/bookmarks", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ url: "https://example.com/api-smoke", title: "API smoke", tags: ["smoke"] }),
});
console.log("seed", seeded.status, seeded.body?.id);

const boot = await api("/api/v1/boot");
console.log("boot", boot.status, "total", boot.body?.initial?.total, "first", boot.body?.initial?.items?.[0]?.id);
const firstId = boot.body.initial.items[0].id;
const bootViews = boot.body?.views || [];
const bootDefault = bootViews.find((view) => view.kind === "graph" && view.is_default === true);
check(
  "the boot payload carries the default graph view",
  Array.isArray(boot.body?.views) && bootViews.length >= 1 && Boolean(bootDefault),
  JSON.stringify(bootViews.map((view) => view.slug))
);
check(
  "the boot view is a full wrapper",
  Boolean(bootDefault) &&
    bootDefault.schema === 1 &&
    typeof bootDefault.id === "number" &&
    typeof bootDefault.slug === "string" &&
    bootDefault.slug.length > 0 &&
    typeof bootDefault.name === "string" &&
    typeof bootDefault.definition === "object" &&
    typeof bootDefault.created_at === "number" &&
    typeof bootDefault.updated_at === "number",
  JSON.stringify(bootDefault)
);
check(
  "the default graph view starts on the standard preset with auto labels",
  bootDefault?.definition?.layout_preset === "standard" &&
    bootDefault?.definition?.label_mode === "auto" &&
    bootDefault?.definition?.tags_shown === true,
  JSON.stringify(bootDefault?.definition)
);
const search = await api("/api/v1/bookmarks?q=rust&limit=2");
console.log("search", search.status, search.body?.total, search.body?.items?.length);
const detail = await api("/api/v1/bookmarks/" + firstId);
console.log("detail", detail.status, detail.body?.id, "tags", detail.body?.tags?.length, "domain", detail.body?.domain);
const patch = await api("/api/v1/bookmarks/" + firstId, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ is_read: true }) });
console.log("patch", patch.status, patch.body);
const backlinks = await api("/api/v1/bookmarks/" + firstId + "/backlinks");
console.log("backlinks", backlinks.status, Object.keys(backlinks.body || {}));
const auto = await api("/api/v1/autocomplete?q=rust");
console.log("autocomplete", auto.status, auto.body?.items?.length);

// The e2e runner imports tests/fixtures/mini-bookmarks.html before this
// script: three records filed on 2023-11-14 UTC from example.com (A, B and C),
// tagged rust (A, B) and toolbar (A). The seeded API record is the fourth.
const list = await api("/api/v1/bookmarks?limit=100");
const items = list.body?.items || [];
const byTitle = new Map(items.map((item) => [item.title, item]));
const fixtureA = byTitle.get("A");
const fixtureB = byTitle.get("B");
check("the mini fixture is seeded", Boolean(fixtureA && fixtureB), list.status + " " + items.length + " items");
if (!fixtureA || !fixtureB) {
  throw new Error("api-smoke needs the mini fixture; run it through scripts/e2e.sh (EZA_E2E_SEED defaults to mini)");
}

const linkPatch = await api("/api/v1/bookmarks/" + fixtureB.id, {
  method: "PATCH",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ note_body: "See [[A]] and [[Missing page]]." }),
});
check("the wikilink note saves", linkPatch.status === 200, String(linkPatch.status));
const linkedDetail = await api("/api/v1/bookmarks/" + fixtureB.id);
const outgoing = linkedDetail.body?.links || [];
const resolvedOut = outgoing.filter((link) => link.resolved);
const unresolvedOut = outgoing.filter((link) => !link.resolved);
check(
  "the note keeps one resolved and one unresolved wikilink",
  resolvedOut.length === 1 &&
    resolvedOut[0].source_id === fixtureA.id &&
    unresolvedOut.length === 1 &&
    unresolvedOut[0].source_title === "Missing page",
  JSON.stringify(outgoing)
);

const yearQuery = await api("/api/v1/bookmarks?q=year:2023&limit=100");
check(
  "q=year:2023 totals the three fixture records",
  yearQuery.status === 200 && yearQuery.body?.total === 3,
  JSON.stringify({ status: yearQuery.status, total: yearQuery.body?.total })
);
const dayQuery = await api("/api/v1/bookmarks?q=day:2023-11-14&limit=100");
check(
  "q=day:2023-11-14 totals the three fixture records",
  dayQuery.status === 200 && dayQuery.body?.total === 3,
  JSON.stringify({ status: dayQuery.status, total: dayQuery.body?.total })
);
const emptyYear = await api("/api/v1/bookmarks?q=year:2024&limit=100");
check(
  "a year with no records totals none",
  emptyYear.status === 200 && emptyYear.body?.total === 0,
  JSON.stringify({ status: emptyYear.status, total: emptyYear.body?.total })
);

const graph = await api("/api/v1/graph");
check("the graph endpoint takes no parameters", graph.status === 200, String(graph.status));
const graphBody = graph.body || {};
const graphTags = graphBody.tags || [];
const graphRecords = graphBody.records || [];
const graphLinks = graphBody.links || [];
check(
  "the graph payload is compact arrays",
  Array.isArray(graphBody.tags) &&
    Array.isArray(graphBody.records) &&
    Array.isArray(graphBody.links) &&
    !("nodes" in graphBody) &&
    !("edges" in graphBody),
  Object.keys(graphBody).join(",")
);
check(
  "a tag is a name and a count",
  graphTags.every((tag) => Array.isArray(tag) && tag.length === 2 && typeof tag[0] === "string" && typeof tag[1] === "number"),
  JSON.stringify(graphTags)
);
check(
  "a record is seven fields with a live status and tag indexes",
  graphRecords.length > 0 &&
    graphRecords.every(
      (record) =>
        Array.isArray(record) &&
        record.length === 7 &&
        typeof record[5] === "boolean" &&
        record[6].every((index) => Number.isInteger(index) && index >= 0 && index < graphTags.length)
    ),
  JSON.stringify(graphRecords)
);
check(
  "the graph carries a revision",
  typeof graphBody.revision === "string" && graphBody.revision.length > 0,
  String(graphBody.revision)
);
check(
  "records ascend by id and cover the whole library",
  graphRecords.length === 4 && graphRecords.every((record, position) => position === 0 || graphRecords[position - 1][0] < record[0]),
  graphRecords.map((record) => record[0]).join(",")
);
check(
  "the fixture tag counts survive the compact wire",
  JSON.stringify(graphTags) === JSON.stringify([["rust", 2], ["smoke", 1], ["toolbar", 1]]),
  JSON.stringify(graphTags)
);
const recordById = new Map(graphRecords.map((record) => [record[0], record]));
const recordA = recordById.get(fixtureA.id);
check(
  "record A keeps its filed date, live status and tag indexes",
  Boolean(recordA) &&
    recordA[3] === 1700000000 &&
    recordA[5] === false &&
    recordA[6].map((index) => graphTags[index][0]).join(",") === "rust,toolbar",
  JSON.stringify(recordA)
);
const seededRecord = recordById.get(seeded.body?.id);
check("the seeded record keeps its read flag", Boolean(seededRecord) && seededRecord[4] === true, JSON.stringify(seededRecord));
check(
  "only the resolved wikilink reaches the graph",
  JSON.stringify(graphLinks) === JSON.stringify([[fixtureB.id, fixtureA.id]]),
  JSON.stringify(graphLinks)
);

// The layout endpoint ships one preset of server-computed positions,
// quantized to 1/100 world unit and keyed to the graph revision.
const layouts = {};
for (const preset of ["compact", "standard", "airy"]) {
  const layout = await api("/api/v1/graph/layout?preset=" + preset);
  const payload = layout.body || {};
  layouts[preset] = payload;
  check("the " + preset + " layout answers", layout.status === 200, String(layout.status));
  check(
    "the " + preset + " layout carries schema and revision",
    payload.schema === 1 && payload.revision === graphBody.revision,
    JSON.stringify({ schema: payload.schema, revision: payload.revision })
  );
  check("the " + preset + " layout names its preset", payload.preset === preset, String(payload.preset));
  check(
    "the " + preset + " layout sizes the position arrays",
    Array.isArray(payload.tags) &&
      Array.isArray(payload.records) &&
      payload.tags.length === graphTags.length &&
      payload.records.length === graphRecords.length,
    JSON.stringify({ tags: payload.tags?.length, records: payload.records?.length })
  );
  check(
    "the " + preset + " layout has four bounds",
    Array.isArray(payload.bounds) && payload.bounds.length === 4 && payload.bounds.every((value) => Number.isFinite(value)),
    JSON.stringify(payload.bounds)
  );
  const positions = [...(payload.tags || []), ...(payload.records || [])];
  check(
    "the " + preset + " positions are [x, y] pairs quantized to 1/100",
    positions.length > 0 &&
      positions.every(
        (position) =>
          Array.isArray(position) &&
          position.length === 2 &&
          position.every((value) => Number.isFinite(value) && Math.abs(value * 100 - Math.round(value * 100)) < 1e-6)
      ),
    JSON.stringify(positions.slice(0, 6))
  );
}
check(
  "the presets ship different positions",
  JSON.stringify(layouts.standard.records) !== JSON.stringify(layouts.compact.records) &&
    JSON.stringify(layouts.standard.records) !== JSON.stringify(layouts.airy.records) &&
    JSON.stringify(layouts.compact.records) !== JSON.stringify(layouts.airy.records),
  JSON.stringify({ compact: layouts.compact.records?.[0], standard: layouts.standard.records?.[0], airy: layouts.airy.records?.[0] })
);
const defaultLayout = await api("/api/v1/graph/layout");
check(
  "the layout endpoint defaults to the standard preset",
  defaultLayout.status === 200 && defaultLayout.body?.preset === "standard",
  JSON.stringify({ status: defaultLayout.status, preset: defaultLayout.body?.preset })
);
const badPreset = await api("/api/v1/graph/layout?preset=huge");
check(
  "an unknown layout preset is a 400",
  badPreset.status === 400 && badPreset.body?.error?.code === "bad_request",
  JSON.stringify({ status: badPreset.status, body: badPreset.body })
);

// Views are stored documents; a graph default is seeded with every database.
const viewsList = await api("/api/v1/views");
const views = viewsList.body?.views || [];
const defaultGraph = views.find((view) => view.kind === "graph" && view.is_default === true);
check(
  "the views list carries the default graph view first",
  viewsList.status === 200 && Array.isArray(viewsList.body?.views) && views.length >= 1 && Boolean(defaultGraph) && views[0].slug === defaultGraph.slug,
  JSON.stringify(views.map((view) => view.slug))
);
check(
  "the listed default view carries its wrapper and definition",
  Boolean(defaultGraph) &&
    defaultGraph.schema === 1 &&
    typeof defaultGraph.id === "number" &&
    typeof defaultGraph.definition === "object" &&
    defaultGraph.definition.layout_preset === "standard",
  JSON.stringify(defaultGraph)
);
const viewDefinition = {
  query: "",
  tags_shown: true,
  label_mode: "auto",
  layout_preset: "compact",
  local_depth: null,
  color_groups: [],
};
const createdView = await api("/api/v1/views", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ name: "API smoke map", kind: "graph", definition: viewDefinition }),
});
check(
  "a graph view can be created",
  createdView.status === 201 &&
    createdView.body?.schema === 1 &&
    createdView.body?.kind === "graph" &&
    createdView.body?.slug === "api-smoke-map" &&
    createdView.body?.name === "API smoke map" &&
    createdView.body?.is_default === false,
  JSON.stringify({ status: createdView.status, body: createdView.body })
);
check(
  "the created view keeps its definition",
  createdView.body?.definition?.layout_preset === "compact" &&
    createdView.body?.definition?.label_mode === "auto" &&
    createdView.body?.definition?.tags_shown === true,
  JSON.stringify(createdView.body?.definition)
);
const fetchedView = await api("/api/v1/views/api-smoke-map");
check(
  "the created view can be fetched by slug",
  fetchedView.status === 200 && fetchedView.body?.id === createdView.body?.id,
  JSON.stringify({ status: fetchedView.status, id: fetchedView.body?.id })
);
const missingView = await api("/api/v1/views/no-such-view");
check("an unknown view slug is a 404", missingView.status === 404, String(missingView.status));
const patchedView = await api("/api/v1/views/api-smoke-map", {
  method: "PATCH",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ name: "API smoke map renamed", is_default: true }),
});
check(
  "a view can be renamed and made the default",
  patchedView.status === 200 &&
    patchedView.body?.name === "API smoke map renamed" &&
    patchedView.body?.is_default === true &&
    patchedView.body?.slug === "api-smoke-map",
  JSON.stringify({ status: patchedView.status, body: patchedView.body })
);
const afterDefault = await api("/api/v1/views");
const graphDefaults = (afterDefault.body?.views || []).filter((view) => view.kind === "graph" && view.is_default === true);
check(
  "one default graph view remains after the patch",
  afterDefault.status === 200 && graphDefaults.length === 1 && graphDefaults[0].slug === "api-smoke-map",
  JSON.stringify(graphDefaults.map((view) => view.slug))
);
const invalidView = await api("/api/v1/views", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ name: "Bad depth", kind: "graph", definition: { ...viewDefinition, local_depth: 9 } }),
});
check(
  "an invalid view definition is a 400",
  invalidView.status === 400 && invalidView.body?.error?.code === "bad_request",
  JSON.stringify({ status: invalidView.status, body: invalidView.body })
);
const deletedView = await api("/api/v1/views/api-smoke-map", { method: "DELETE" });
check("a view can be deleted", deletedView.status === 204, String(deletedView.status));
const goneView = await api("/api/v1/views/api-smoke-map");
check("the deleted view is gone", goneView.status === 404, String(goneView.status));
const restoredList = await api("/api/v1/views");
const restoredDefaults = (restoredList.body?.views || []).filter((view) => view.kind === "graph" && view.is_default === true);
check(
  "deleting the default promotes a graph view again",
  restoredList.status === 200 && restoredDefaults.length === 1 && restoredDefaults[0].slug === bootDefault?.slug,
  JSON.stringify(restoredDefaults.map((view) => view.slug))
);

const savedCreate = await api("/api/v1/saved-searches", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name: "Rust", q: "rust", tags: [] }) });
console.log("saved create", savedCreate.status, savedCreate.body);
const savedList = await api("/api/v1/saved-searches");
console.log("saved list", savedList.status, savedList.body?.saved_searches?.length);
const dedup = await api("/api/v1/dedup/candidates?url_limit=5&title_limit=5");
console.log("dedup", dedup.status, dedup.body?.counts);
const mergeAllRefused = await api("/api/v1/dedup/merge-all", { method: "POST", body: JSON.stringify({}) });
console.log("dedup merge-all refused", mergeAllRefused.status, mergeAllRefused.body?.error?.code);
const mergeAll = await api("/api/v1/dedup/merge-all", { method: "POST", body: JSON.stringify({ confirm: true }) });
console.log("dedup merge-all", mergeAll.status, mergeAll.body);
const tags = await api("/api/v1/tags/consolidation-candidates");
console.log("tags cleanup", tags.status, tags.body?.groups?.length);
const prune = await api("/api/v1/maintenance/prune-candidates");
console.log("prune candidates", prune.status, prune.body?.items?.length);
const account = await api("/api/v1/account");
console.log("account", account.status, Object.keys(account.body || {}), account.body?.recovery_codes_remaining);
check("the account document names the signed-in user", account.status === 200 && account.body?.username === (process.env.EZA_TEST_USER || "e2e"), JSON.stringify({ status: account.status, username: account.body?.username }));

// Administration: one admin account manages the other accounts in the
// control database. Management routes are session-only.
const adminUsers = await api("/api/v1/admin/users");
const adminList = adminUsers.body?.users || [];
const selfUser = adminList.find((user) => user.username === (process.env.EZA_TEST_USER || "e2e"));
check(
  "the admin users list carries the signed-in admin",
  adminUsers.status === 200 && Boolean(selfUser) && selfUser.role === "admin" && selfUser.disabled_at === null,
  JSON.stringify(adminList)
);
check(
  "the admin user wrapper hides the database path",
  adminList.length > 0 && adminList.every((user) => !("db_path" in user) && !("handle" in user)),
  Object.keys(adminList[0] || {}).join(",")
);
if (!selfUser) {
  throw new Error("api-smoke needs the harness admin account");
}
const createdUser = await api("/api/v1/admin/users", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ username: "api-smoke-member", password: "api-smoke-password-1", role: "member" }),
});
check(
  "an admin can create a member account",
  createdUser.status === 201 &&
    createdUser.body?.user?.username === "api-smoke-member" &&
    createdUser.body?.user?.role === "member" &&
    Array.isArray(createdUser.body?.recovery_codes) &&
    createdUser.body.recovery_codes.length === 10,
  JSON.stringify({ status: createdUser.status, user: createdUser.body?.user, codes: createdUser.body?.recovery_codes?.length })
);
const memberId = createdUser.body?.user?.id;
const duplicateUser = await api("/api/v1/admin/users", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ username: "api-smoke-member", password: "api-smoke-password-1", role: "member" }),
});
check(
  "a duplicate username is a 409 username_taken",
  duplicateUser.status === 409 && duplicateUser.body?.error?.code === "username_taken",
  JSON.stringify({ status: duplicateUser.status, body: duplicateUser.body })
);
const weakUser = await api("/api/v1/admin/users", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ username: "api-smoke-weak", password: "short", role: "member" }),
});
check(
  "a weak password is a 400 weak_password",
  weakUser.status === 400 && weakUser.body?.error?.code === "weak_password",
  JSON.stringify({ status: weakUser.status, body: weakUser.body })
);
const disabledMember = await api("/api/v1/admin/users/" + memberId, {
  method: "PATCH",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ enabled: false }),
});
check(
  "an admin can disable a member",
  disabledMember.status === 200 && typeof disabledMember.body?.disabled_at === "number",
  JSON.stringify({ status: disabledMember.status, body: disabledMember.body })
);
const enabledMember = await api("/api/v1/admin/users/" + memberId, {
  method: "PATCH",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ enabled: true }),
});
check(
  "an admin can enable a member",
  enabledMember.status === 200 && enabledMember.body?.disabled_at === null,
  JSON.stringify({ status: enabledMember.status, body: enabledMember.body })
);
const resetMember = await api("/api/v1/admin/users/" + memberId + "/password", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ password: "api-smoke-password-2" }),
});
check("an admin can reset a member password", resetMember.status === 200 && resetMember.body?.ok === true, JSON.stringify({ status: resetMember.status, body: resetMember.body }));
const selfDisable = await api("/api/v1/admin/users/" + selfUser.id, {
  method: "PATCH",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ enabled: false }),
});
check(
  "an admin cannot disable its own account",
  selfDisable.status === 409 && selfDisable.body?.error?.code === "self_disable",
  JSON.stringify({ status: selfDisable.status, body: selfDisable.body })
);
const lastAdmin = await api("/api/v1/admin/users/" + selfUser.id, {
  method: "PATCH",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ role: "member" }),
});
check(
  "the last enabled admin cannot be demoted",
  lastAdmin.status === 409 && lastAdmin.body?.error?.code === "last_admin",
  JSON.stringify({ status: lastAdmin.status, body: lastAdmin.body })
);
const adminToken = await api("/api/v1/tokens", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ name: "admin-route-check", scopes: ["read"] }),
});
const bearerAdmin = await page.evaluate(async (token) => {
  const response = await fetch("/api/v1/admin/users", { headers: { Authorization: "Bearer " + token } });
  let body = null;
  try { body = await response.json(); } catch (_) { body = null; }
  return { status: response.status, body };
}, adminToken.body?.token);
check(
  "a bearer token cannot reach admin routes",
  bearerAdmin.status === 403 && bearerAdmin.body?.error?.code === "session_required",
  JSON.stringify({ status: bearerAdmin.status, body: bearerAdmin.body })
);
const exported = await api("/api/v1/export");
console.log("export", exported.status, exported.contentType, typeof exported.body === "string" ? exported.body.slice(0, 40) : "json");

const importResult = await page.evaluate(async () => {
  const csrf = document.cookie.split("; ").find((c) => c.startsWith("eza_csrf="))?.split("=")[1] || "";
  const html = '<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DL><p>\n<DT><A HREF="https://example.com/eza-smoke" ADD_DATE="1700000000">Smoke</A>\n</DL><p>';
  const fd = new FormData();
  fd.append("file", new Blob([html], { type: "text/html" }), "smoke.html");
  const r = await fetch("/api/v1/import", { method: "POST", headers: { "X-CSRF-Token": csrf }, body: fd });
  return { status: r.status, body: await r.json() };
});
console.log("import", importResult.status, importResult.body?.inserted, importResult.body?.unique_urls);

report(errors);
await browser.close();
