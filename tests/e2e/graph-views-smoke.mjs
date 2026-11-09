// Graph views smoke test (M1): hydrated layout, label LOD, layout presets,
// local graph depth, colour groups, the views manager and ledger views.
//
// The script seeds its own bulk library through the import API so the label
// budgets and colour groups have enough nodes; a runner-seeded mini fixture (if
// present) only adds a few records and does not change the bulk-tag counts.
//
// The current e2e harness still seeds the legacy single-user database; run this
// script once task-21 moves the harness to a claimed multi-user install, with:
//   EZA_E2E_SCRIPTS=graph-views-smoke.mjs bash scripts/e2e.sh
import { BASE, SEL, launchBrowser, launchPage, enterLibrary, makeApi, newChecker } from "./lib/dom.mjs";

const BULK = 400;
const GROUP_NAME = "Bulk";
const GROUP_QUERY = "tag:bulk";
const GROUP_COLOR = "#FF0000";
const DRAG_BUDGET_MS = 33;

const browser = await launchBrowser();
const { page, errors } = await launchPage(browser, { viewport: { width: 1440, height: 950 } });
const { check, report } = newChecker();
const api = makeApi(page);

// The preset buttons are driven by the client state, which can land a frame
// after the layout response the test waits on. Poll the attribute instead of
// reading it once, so a slow frame does not read as a product failure.
const waitPressed = async (selector) => {
  await page
    .waitForFunction((sel) => document.querySelector(sel)?.getAttribute("aria-pressed") === "true", selector, { timeout: 10000 })
    .catch(() => {});
};

const layoutRequests = [];
const graphRequests = [];
page.on("response", (response) => {
  const url = new URL(response.url());
  if (url.pathname === "/api/v1/graph") graphRequests.push(1);
  if (url.pathname === "/api/v1/graph/layout") layoutRequests.push(url.searchParams.get("preset"));
});

// ---------------------------------------------------------------- helpers ---

async function canvasCounts() {
  return page.evaluate((selector) => {
    const canvas = document.querySelector(selector);
    if (!canvas || !canvas.width || !canvas.height) return { opaque: 0, red: 0 };
    const context = canvas.getContext("2d");
    if (!context) return { opaque: 0, red: 0 };
    const data = context.getImageData(0, 0, canvas.width, canvas.height).data;
    let opaque = 0;
    let red = 0;
    // Sample every fourth pixel; the plate is far larger than the thresholds.
    for (let index = 0; index < data.length; index += 16) {
      if (data[index + 3] !== 0) opaque += 1;
      if (data[index] > 170 && data[index + 1] < 90 && data[index + 2] < 90) red += 1;
    }
    return { opaque, red };
  }, SEL.graphCanvas);
}

async function waitForPaintedCanvas() {
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    if ((await canvasCounts()).opaque > 100) return;
    await page.waitForTimeout(50);
  }
  throw new Error("the graph canvas stayed blank");
}

async function waitForGraph() {
  await page.waitForSelector(SEL.graph, { timeout: 30000 });
  await page.waitForSelector(SEL.graphStatus, { timeout: 30000 });
  await waitForPaintedCanvas();
}

async function waitForRedPixels() {
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    if ((await canvasCounts()).red > 5) return true;
    await page.waitForTimeout(100);
  }
  return false;
}

async function statusMain() {
  return ((await page.locator(SEL.graphStatusMain).first().innerText()) || "").replace(/\s+/g, " ").trim();
}

async function waitForStatus(pattern) {
  return page
    .waitForFunction(
      ({ selector, source }) => new RegExp(source).test(document.querySelector(selector)?.textContent || ""),
      { selector: SEL.graphStatusMain, source: pattern.source },
      { timeout: 20000 }
    )
    .then(() => true)
    .catch(() => false);
}

async function labelCount() {
  const text = (await page.locator(SEL.graphLabelCount).first().innerText()) || "";
  const match = text.match(/(\d+)/);
  return match ? Number(match[1]) : Number.NaN;
}

async function zoomPercent() {
  const text = (await page.locator(SEL.graphZoomValue).first().innerText()) || "";
  const match = text.match(/(\d+)/);
  return match ? Number(match[1]) : Number.NaN;
}

async function waitForZoom(operator, value) {
  return page
    .waitForFunction(
      ({ selector, operator, value }) => {
        const match = (document.querySelector(selector)?.textContent || "").match(/(\d+)/);
        if (!match) return false;
        const current = Number(match[1]);
        if (operator === ">") return current > value;
        if (operator === "<") return current < value;
        return current === value;
      },
      { selector: SEL.graphZoomValue, operator, value },
      { timeout: 15000 }
    )
    .then(() => true)
    .catch(() => false);
}

function firstRecordCount(status) {
  const match = status.match(/([\d,]+) records/);
  return match ? Number(match[1].replace(/,/g, "")) : Number.NaN;
}

async function waitForPath(pathname) {
  await page.waitForURL((url) => url.pathname === pathname, { timeout: 20000 }).catch(() => {});
  return new URL(page.url()).pathname;
}

function rowByName(name) {
  return page.locator(SEL.viewRow).filter({ hasText: name });
}

async function waitForRows() {
  await page.waitForSelector(SEL.viewsPage, { timeout: 20000 });
  await page.waitForSelector(SEL.viewRow, { timeout: 20000 });
}

function netscape(count) {
  const lines = [
    "<!DOCTYPE NETSCAPE-Bookmark-file-1>",
    "<TITLE>Bulk</TITLE>",
    "<H1>Bulk</H1>",
    "<DL><p>",
  ];
  for (let index = 0; index < count; index += 1) {
    const title =
      index === 0
        ? "Bulk root"
        : index === 1
          ? "Bulk middle"
          : index === 2
            ? "Bulk leaf"
            : "Bulk record " + String(index).padStart(3, "0");
    // The first three carry the newest save dates so the ledger search for
    // "bulk" lists them first and the local graph can be rooted on record 0.
    const added = index < 3 ? 1700001000 + index : 1700000000 + index;
    lines.push(
      '    <DT><A HREF="https://bulk.example/' +
        index +
        '" ADD_DATE="' +
        added +
        '" TAGS="bulk">' +
        title +
        "</A>"
    );
  }
  lines.push("</DL><p>");
  return lines.join("\n");
}

async function importBulk(html) {
  return page.evaluate(async (body) => {
    const csrf =
      document.cookie
        .split("; ")
        .find((cookie) => cookie.startsWith("eza_csrf="))
        ?.split("=")[1] || "";
    const form = new FormData();
    form.append("file", new File([body], "bulk.html", { type: "text/html" }));
    const response = await fetch("/api/v1/import", {
      method: "POST",
      body: form,
      headers: { Accept: "application/json", "X-CSRF-Token": csrf },
    });
    let result = null;
    try {
      result = await response.json();
    } catch (_) {
      result = null;
    }
    return { status: response.status, body: result };
  }, html);
}

async function framesDuring(work) {
  await page.evaluate(() => {
    window.__ezaSmokeFrames = [];
    window.__ezaSmokeLast = performance.now();
    window.__ezaSmokeOn = true;
    const tick = (now) => {
      if (!window.__ezaSmokeOn) return;
      window.__ezaSmokeFrames.push(now - window.__ezaSmokeLast);
      window.__ezaSmokeLast = now;
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  });
  await work();
  return page.evaluate(() => {
    window.__ezaSmokeOn = false;
    const values = window.__ezaSmokeFrames.slice(1).sort((a, b) => a - b);
    if (!values.length) return { count: 0, p50: 0, p95: 0 };
    const at = (p) => values[Math.min(values.length - 1, Math.floor(values.length * p))];
    return { count: values.length, p50: at(0.5), p95: at(0.95) };
  });
}

try {
  await enterLibrary(page);
  await page.waitForSelector(SEL.appShell, { timeout: 60000 });

  // ------------------------------------------------------ seed bulk library ---
  const imported = await importBulk(netscape(BULK));
  const inserted = imported.body?.inserted ?? 0;
  check("the bulk fixture imports", imported.status === 200 && inserted === BULK, JSON.stringify(imported));
  const bulkRecords = inserted || BULK;

  const list = await api("/api/v1/bookmarks?q=bulk&limit=20");
  const items = list.body?.items || [];
  const root = items.find((item) => item.title === "Bulk root");
  const middle = items.find((item) => item.title === "Bulk middle");
  const leaf = items.find((item) => item.title === "Bulk leaf");
  check("the bulk records can be listed", Boolean(root && middle && leaf), JSON.stringify(items.slice(0, 4).map((item) => item.title)));
  if (!root || !middle || !leaf) {
    throw new Error("graph-views-smoke could not find the seeded bulk records");
  }
  const middleLink = await api("/api/v1/bookmarks/" + middle.id, {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ note_body: "[[Bulk root]]" }),
  });
  const leafLink = await api("/api/v1/bookmarks/" + leaf.id, {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ note_body: "[[Bulk middle]]" }),
  });
  check("the local-graph wikilinks save", middleLink.status === 200 && leafLink.status === 200, String(middleLink.status) + "/" + String(leafLink.status));

  // ------------------------------------------------ hydrated whole graph ---
  const firstGraph = page.waitForResponse((response) => new URL(response.url()).pathname === "/api/v1/graph");
  const firstLayout = page.waitForResponse((response) => new URL(response.url()).pathname === "/api/v1/graph/layout");
  await page.click(SEL.section("graph"));
  const [graphResponse, layoutResponse] = await Promise.all([firstGraph, firstLayout]);
  await waitForGraph();
  const graphPayload = await graphResponse.json();
  const layoutPayload = await layoutResponse.json();
  check("the first graph fetch carries the whole library", Array.isArray(graphPayload.records) && graphPayload.records.length >= bulkRecords, String(graphPayload.records?.length));
  check(
    "the layout hydrates the graph revision",
    layoutPayload.schema === 1 &&
      typeof layoutPayload.revision === "string" &&
      layoutPayload.revision === graphPayload.revision &&
      layoutPayload.preset === "standard",
    JSON.stringify({ schema: layoutPayload.schema, revision: layoutPayload.revision, preset: layoutPayload.preset })
  );
  check(
    "the layout positions match the graph arrays",
    Array.isArray(layoutPayload.tags) &&
      Array.isArray(layoutPayload.records) &&
      layoutPayload.tags.length === graphPayload.tags.length &&
      layoutPayload.records.length === graphPayload.records.length,
    JSON.stringify({ tags: layoutPayload.tags?.length, records: layoutPayload.records?.length })
  );
  await waitForStatus(/server layout/);
  check("the status reports the server layout", /server layout/.test(await statusMain()), await statusMain());
  check("the label readout is present", Number.isFinite(await labelCount()), String(await labelCount()));
  check("the standard preset is pressed by default", (await page.locator(SEL.graphPresetStandard).getAttribute("aria-pressed")) === "true", String(await page.locator(SEL.graphPresetStandard).getAttribute("aria-pressed")));

  // ---------------------------------------------------------- label LOD ---
  const overviewLabels = await labelCount();
  for (let index = 0; index < 4; index += 1) {
    await page.click(SEL.graphZoomIn);
    await page.waitForTimeout(60);
  }
  await page.waitForFunction((selector) => /\d+/.test(document.querySelector(selector)?.textContent || ""), SEL.graphZoomValue);
  const zoomedLabels = await labelCount();
  const zoomedPercent = await zoomPercent();
  check("zooming raises the zoom readout", zoomedPercent > 200, String(zoomedPercent));
  check("the label count changes with zoom", zoomedLabels !== overviewLabels, overviewLabels + " -> " + zoomedLabels);
  await page.click(SEL.graphFit);
  await page.waitForTimeout(100);

  // ------------------------------------------------------ layout presets ---
  const layoutsBeforePreset = layoutRequests.length;
  const graphFetchesBeforePreset = graphRequests.length;
  const compactLayout = page.waitForResponse((response) => {
    const url = new URL(response.url());
    return url.pathname === "/api/v1/graph/layout" && url.searchParams.get("preset") === "compact";
  });
  await page.click(SEL.graphPresetCompact);
  await compactLayout;
  await waitPressed(SEL.graphPresetCompact);
  check("the compact preset asks for its layout", layoutRequests.length > layoutsBeforePreset, JSON.stringify(layoutRequests.slice(-3)));
  check("a preset change does not refetch the graph", graphRequests.length === graphFetchesBeforePreset, String(graphRequests.length - graphFetchesBeforePreset));
  check("the compact preset button is pressed", (await page.locator(SEL.graphPresetCompact).getAttribute("aria-pressed")) === "true", String(await page.locator(SEL.graphPresetCompact).getAttribute("aria-pressed")));

  const airyLayout = page.waitForResponse((response) => {
    const url = new URL(response.url());
    return url.pathname === "/api/v1/graph/layout" && url.searchParams.get("preset") === "airy";
  });
  await page.click(SEL.graphPresetAiry);
  await airyLayout;
  await waitPressed(SEL.graphPresetAiry);
  check("the airy preset button is pressed", (await page.locator(SEL.graphPresetAiry).getAttribute("aria-pressed")) === "true", String(await page.locator(SEL.graphPresetAiry).getAttribute("aria-pressed")));
  const compactAgain = page.waitForResponse((response) => {
    const url = new URL(response.url());
    return url.pathname === "/api/v1/graph/layout" && url.searchParams.get("preset") === "compact";
  });
  await page.click(SEL.graphPresetCompact);
  await compactAgain;

  await page.click(SEL.viewSaveGraph);
  await page.waitForSelector(SEL.toast, { timeout: 20000 }).catch(() => {});
  await page.waitForTimeout(300);
  const reloadedLayout = page.waitForResponse((response) => {
    const url = new URL(response.url());
    return url.pathname === "/api/v1/graph/layout" && url.searchParams.get("preset") === "compact";
  });
  await page.reload({ waitUntil: "domcontentloaded" });
  await waitForGraph();
  await reloadedLayout.catch(() => {});
  await waitPressed(SEL.graphPresetCompact);
  check("the preset survives a reload", (await page.locator(SEL.graphPresetCompact).getAttribute("aria-pressed")) === "true", String(await page.locator(SEL.graphPresetCompact).getAttribute("aria-pressed")));

  // ------------------------------------------------------- local graph ---
  // A cold load of the local deeplink is a required behaviour: the query route
  // must win over the default view. The client currently applies the default
  // view after the route on a full page load, so the cold check stays visible
  // as a failure while the same URL through the client router is exercised for
  // the interaction checks below.
  const localUrl = "/graph?focus=" + root.id + "&depth=2&local=1";
  await page.goto(BASE + localUrl, { waitUntil: "domcontentloaded" });
  await waitForGraph();
  await page.waitForTimeout(800);
  const coldStatus = await statusMain();
  const coldRoot = await page.locator(SEL.graphRoot).first().innerText().catch(() => "");
  check("a cold deeplink load enters local mode", /depth 2/.test(coldStatus), coldStatus);
  check("a cold deeplink load names its root", coldRoot.trim() === "Bulk root", coldRoot || coldStatus);
  await page.evaluate((url) => {
    history.pushState(null, "", url);
    window.dispatchEvent(new PopStateEvent("popstate"));
  }, localUrl);
  await waitForStatus(/depth 2/);
  const localStatus = await statusMain();
  check("the deeplink route reports depth 2", /depth 2/.test(localStatus), localStatus);
  const rootedTitle = await page.locator(SEL.graphRoot).first().innerText().catch(() => "");
  check("the deeplink route names its root", rootedTitle.trim() === "Bulk root", rootedTitle || localStatus);

  // The local graph is a graph route: it must keep the documented keyboard
  // controls even though it is not the plain /graph URL.
  const localFocus = await page.evaluate(() => document.activeElement && document.activeElement.id);
  check("the local graph focuses its canvas", localFocus === "graph-canvas", String(localFocus));
  const localFitZoom = await zoomPercent();
  await page.locator(SEL.graphStatus).first().click();
  await page.keyboard.press("+");
  const localZoomed = await waitForZoom(">", localFitZoom);
  check("+ zooms the local graph", localZoomed && (await zoomPercent()) > localFitZoom, localFitZoom + " -> " + (await zoomPercent()));
  await page.fill(SEL.graphFilter, "zzz-no-local-match");
  const localFilterSet = await waitForStatus(/match the filter/);
  check("the local graph filter applies", localFilterSet, await statusMain());
  await page.locator(SEL.graphStatus).first().click();
  await page.keyboard.press("Escape");
  const localEsc = await page
    .waitForFunction((selector) => (document.querySelector(selector)?.value || "") === "", SEL.graphFilter, { timeout: 15000 })
    .then(() => true)
    .catch(() => false);
  check("Esc clears the local graph filter", localEsc, await page.locator(SEL.graphFilter).inputValue());
  await page.click(SEL.graphFit);
  await page.waitForTimeout(100);
  const depthTwoRecords = firstRecordCount(localStatus);
  await page.click(SEL.graphDepth(1));
  const depthOne = await waitForStatus(/depth 1/);
  const depthOneStatus = await statusMain();
  check("the depth selector changes the local graph", depthOne, depthOneStatus);
  check("the shallower depth holds fewer records", firstRecordCount(depthOneStatus) < depthTwoRecords, depthTwoRecords + " -> " + firstRecordCount(depthOneStatus));
  await page.click(SEL.graphScopeWhole);
  const leftLocal = await page
    .waitForFunction(
      ({ selector }) => {
        const text = document.querySelector(selector)?.textContent || "";
        return text.includes("records") && !/depth \d/.test(text);
      },
      { selector: SEL.graphStatusMain },
      { timeout: 20000 }
    )
    .then(() => true)
    .catch(() => false);
  check("the whole-scope button leaves the local graph", leftLocal, await statusMain());
  check("the whole graph has no local root", (await page.locator(SEL.graphRoot).count()) === 0, String(await page.locator(SEL.graphRoot).count()));

  // Esc also clears the pinned selection, not just the filter line.
  await page.goto(BASE + "/bookmark/" + root.id, { waitUntil: "domcontentloaded" });
  await page.waitForSelector(SEL.record, { timeout: 30000 });
  await page.click(SEL.openGraph);
  await page.waitForSelector(SEL.graph, { timeout: 30000 });
  await waitForGraph();
  await page.waitForFunction((selector) => (document.querySelector(selector)?.textContent || "").includes("Bulk root"), SEL.graphPreview, { timeout: 15000 }).catch(() => {});
  await page.click(SEL.graphLocalToggle);
  const localFromSelection = await waitForStatus(/depth 1/);
  const pinnedPreview = ((await page.locator(SEL.graphPreview).first().innerText()) || "").replace(/\s+/g, " ").trim();
  check("the local graph pins the selected record", localFromSelection && pinnedPreview.includes("Bulk root"), pinnedPreview);
  await page.locator(SEL.graphStatus).first().click();
  await page.keyboard.press("Escape");
  const selectionCleared = await page
    .waitForFunction((selector) => /Hover a node to preview it/.test(document.querySelector(selector)?.textContent || ""), SEL.graphPreview, { timeout: 15000 })
    .then(() => true)
    .catch(() => false);
  check(
    "Esc clears the local graph selection",
    selectionCleared,
    ((await page.locator(SEL.graphPreview).first().innerText()) || "").replace(/\s+/g, " ").trim()
  );

  // ------------------------------------------------------- colour groups ---
  await page.goto(BASE + "/graph", { waitUntil: "domcontentloaded" });
  await waitForGraph();
  await page.click(SEL.graphGroupEdit);
  await page.waitForSelector(SEL.graphGroupEditor, { timeout: 15000 });
  await page.click(SEL.graphGroupAdd);
  await page.waitForFunction((selector) => document.querySelectorAll(selector).length === 1, SEL.graphGroupRow);
  const groupRow = page.locator(SEL.graphGroupRow).first();
  await groupRow.locator(SEL.graphGroupName).fill(GROUP_NAME);
  await groupRow.locator(SEL.graphGroupQuery).fill(GROUP_QUERY);
  await groupRow.locator(SEL.graphGroupColor).fill(GROUP_COLOR);
  await page.waitForFunction(
    ({ legend, name }) => (document.querySelector(legend)?.textContent || "").includes(name),
    { legend: SEL.graphLegend, name: GROUP_NAME },
    { timeout: 15000 }
  );
  await page
    .waitForFunction(
      ({ expected }) => {
        const node = document.querySelector('[data-testid="graph-legend"] .g-legend-count');
        const match = (node?.textContent || "").match(/([\d,]+)/);
        return Boolean(match) && Number(match[1].replace(/,/g, "")) === expected;
      },
      { expected: bulkRecords },
      { timeout: 20000 }
    )
    .catch(() => {});
  const legendCount = await page.evaluate(() => {
    const node = document.querySelector('[data-testid="graph-legend"] .g-legend-count');
    const match = (node?.textContent || "").match(/([\d,]+)/);
    return match ? Number(match[1].replace(/,/g, "")) : Number.NaN;
  });
  check("the legend counts the matching records", legendCount === bulkRecords, String(legendCount));
  check("the group paints the canvas", await waitForRedPixels(), JSON.stringify(await canvasCounts()));

  await groupRow.locator(SEL.graphGroupColor).fill("#zzzzzz");
  await page.click(SEL.graphGroupsSave);
  const invalidColour = await page
    .waitForFunction(
      () => {
        const node = document.querySelector('[data-testid="graph-group-editor"] .add-error');
        return Boolean(node && /color/i.test(node.textContent || ""));
      },
      { timeout: 15000 }
    )
    .then(() => true)
    .catch(() => false);
  const colourError = await page.evaluate(() => document.querySelector('[data-testid="graph-group-editor"] .add-error')?.textContent || "");
  check("an invalid colour is rejected inline", invalidColour && colourError.length > 0, colourError);
  await groupRow.locator(SEL.graphGroupColor).fill(GROUP_COLOR);
  await page.click(SEL.graphGroupsSave);
  await page.waitForSelector(SEL.graphGroupEditor, { state: "detached", timeout: 20000 }).catch(() => {});

  await page.reload({ waitUntil: "domcontentloaded" });
  await waitForGraph();
  check(
    "the colour group survives a reload",
    ((await page.locator(SEL.graphLegend).first().innerText()) || "").includes(GROUP_NAME),
    await page.locator(SEL.graphLegend).first().innerText()
  );
  check("the persisted group still paints", await waitForRedPixels(), JSON.stringify(await canvasCounts()));

  await page.click(SEL.graphGroupEdit);
  await page.waitForSelector(SEL.graphGroupEditor, { timeout: 15000 });
  for (let index = 0; index < 30; index += 1) {
    const rows = await page.locator(SEL.graphGroupRow).count();
    if (rows >= 24) break;
    await page.click(SEL.graphGroupAdd);
    await page.waitForTimeout(20);
  }
  check("the group editor caps at 24 groups", (await page.locator(SEL.graphGroupRow).count()) === 24, String(await page.locator(SEL.graphGroupRow).count()));
  await page.click(SEL.graphGroupsCancel);
  await page.waitForSelector(SEL.graphGroupEditor, { state: "detached", timeout: 15000 }).catch(() => {});
  check("cancelling the group editor keeps the saved group", (await page.locator(SEL.graphLegend + " .g-legend-row").count()) === 1, String(await page.locator(SEL.graphLegend + " .g-legend-row").count()));

  // --------------------------------------------------------- label mode ---
  const viewsBefore = await api("/api/v1/views");
  const defaultGraphView = (viewsBefore.body?.views || []).find((view) => view.kind === "graph" && view.is_default === true);
  check("the views API carries the default graph view", Boolean(defaultGraphView), JSON.stringify(viewsBefore.body?.views?.map((view) => view.slug)));
  if (!defaultGraphView) {
    throw new Error("graph-views-smoke needs a default graph view");
  }
  const noLabels = await api("/api/v1/views", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      name: "No labels",
      kind: "graph",
      definition: { ...defaultGraphView.definition, label_mode: "none" },
    }),
  });
  check("a graph view with label mode none is created", noLabels.status === 201 && noLabels.body?.definition?.label_mode === "none", JSON.stringify({ status: noLabels.status, body: noLabels.body }));
  const noLabelsDefault = await api("/api/v1/views/" + noLabels.body.slug, {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ is_default: true }),
  });
  check("the label-mode view can become the default", noLabelsDefault.status === 200 && noLabelsDefault.body?.is_default === true, String(noLabelsDefault.status));
  await page.goto(BASE + "/graph", { waitUntil: "domcontentloaded" });
  await waitForGraph();
  await page
    .waitForFunction((selector) => /(^|\D)0 labels/.test(document.querySelector(selector)?.textContent || ""), SEL.graphLabelCount, { timeout: 15000 })
    .catch(() => {});
  check("label mode none hides every label", (await labelCount()) === 0, String(await labelCount()));
  await api("/api/v1/views/" + noLabels.body.slug, { method: "DELETE" });

  // ------------------------------------------------------- views manager ---
  await page.click(SEL.section("views"));
  await waitForRows();
  await page
    .waitForFunction(
      ({ selector, name }) => ![...document.querySelectorAll(selector)].some((row) => (row.textContent || "").includes(name)),
      { selector: SEL.viewRow, name: "No labels" },
      { timeout: 20000 }
    )
    .catch(() => {});
  const initialRows = await page.locator(SEL.viewRow).count();
  check("the views page lists saved views", initialRows >= 1, String(initialRows));
  check("exactly one default badge shows", (await page.locator(SEL.viewDefaultBadge).count()) === 1, String(await page.locator(SEL.viewDefaultBadge).count()));

  await page.click(SEL.viewCreate);
  await page.waitForSelector(SEL.viewSaveDialog, { timeout: 15000 });
  const saveDialogRole = await page.locator(SEL.viewSaveDialog).first().getAttribute("role");
  const saveDialogModal = await page.locator(SEL.viewSaveDialog).first().getAttribute("aria-modal");
  const saveDialogLabel = await page.locator(SEL.viewSaveDialog).first().getAttribute("aria-label");
  check(
    "the view save dialog is a labelled modal",
    saveDialogRole === "dialog" && saveDialogModal === "true" && Boolean((saveDialogLabel || "").trim()),
    JSON.stringify({ role: saveDialogRole, modal: saveDialogModal, label: saveDialogLabel })
  );
  const trapInner = async (last) =>
    page.evaluate(
      ({ selector, last }) => {
        const dialog = document.querySelector(selector);
        if (!dialog) return false;
        const focusable = dialog.querySelectorAll("button, input, textarea, a[href]");
        if (!focusable.length) return false;
        focusable[last ? focusable.length - 1 : 0].focus();
        return true;
      },
      { selector: SEL.viewSaveDialog, last }
    );
  await trapInner(true);
  await page.keyboard.press("Tab");
  const trapForward = await page.evaluate((selector) => {
    const dialog = document.querySelector(selector);
    return Boolean(dialog && document.activeElement && dialog.contains(document.activeElement));
  }, SEL.viewSaveDialog);
  await trapInner(false);
  await page.keyboard.press("Shift+Tab");
  const trapBack = await page.evaluate((selector) => {
    const dialog = document.querySelector(selector);
    return Boolean(dialog && document.activeElement && dialog.contains(document.activeElement));
  }, SEL.viewSaveDialog);
  check("the view save dialog traps Tab at both ends", trapForward && trapBack, JSON.stringify({ trapForward, trapBack }));
  await page.fill(SEL.viewNameInput, "Smoke graph view");
  await page.click(SEL.viewSaveSubmit);
  await page.waitForSelector(SEL.viewSaveDialog, { state: "detached", timeout: 20000 }).catch(() => {});
  await page.waitForFunction((selector) => [...document.querySelectorAll(selector)].some((row) => (row.textContent || "").includes("Smoke graph view")), SEL.viewRow, { timeout: 20000 });
  check("a graph view can be created from the manager", (await rowByName("Smoke graph view").count()) === 1);
  check("creating a view keeps one default", (await page.locator(SEL.viewDefaultBadge).count()) === 1, String(await page.locator(SEL.viewDefaultBadge).count()));

  await page.click(SEL.section("graph"));
  await waitForGraph();
  await page.click(SEL.viewSaveAs);
  await page.waitForSelector(SEL.viewSaveDialog, { timeout: 15000 });
  await page.fill(SEL.viewNameInput, "Smoke save as view");
  await page.click(SEL.viewSaveSubmit);
  await page.waitForSelector(SEL.viewSaveDialog, { state: "detached", timeout: 20000 }).catch(() => {});
  await page.click(SEL.section("views"));
  await waitForRows();
  await page.waitForFunction((selector) => [...document.querySelectorAll(selector)].some((row) => (row.textContent || "").includes("Smoke save as view")), SEL.viewRow, { timeout: 20000 });
  check("save as adds a named view", (await rowByName("Smoke save as view").count()) === 1);

  await rowByName("Smoke graph view").locator(SEL.viewOpen).click();
  check("opening a saved graph view lands on /graph", (await waitForPath("/graph")) === "/graph", page.url());
  await waitForGraph();

  await page.click(SEL.section("views"));
  await waitForRows();
  await rowByName("Smoke graph view").locator(SEL.viewDefault).click();
  await rowByName("Smoke graph view").locator(SEL.viewDefaultBadge).waitFor({ timeout: 20000 }).catch(() => {});
  check("setting a default moves the single badge", (await page.locator(SEL.viewDefaultBadge).count()) === 1, String(await page.locator(SEL.viewDefaultBadge).count()));

  await rowByName("Smoke graph view").locator(SEL.viewDelete).click();
  await rowByName("Smoke graph view").waitFor({ state: "detached", timeout: 20000 }).catch(() => {});
  // Deleting the default view promotes another view server-side; the manager
  // must show that surviving default without waiting for a page reload.
  const promotedDefault = await page
    .waitForFunction((selector) => document.querySelectorAll(selector).length === 1, SEL.viewDefaultBadge, { timeout: 20000 })
    .then(() => true)
    .catch(() => false);
  check(
    "deleting the default view promotes the next default",
    promotedDefault,
    "badges=" + (await page.locator(SEL.viewDefaultBadge).count())
  );
  await page.reload({ waitUntil: "domcontentloaded" });
  await waitForRows();
  check("deleting a view leaves a default again", (await page.locator(SEL.viewDefaultBadge).count()) === 1, String(await page.locator(SEL.viewDefaultBadge).count()));

  await page.click(SEL.viewImport);
  await page.waitForSelector(SEL.viewImportDialog, { timeout: 15000 });
  await page.fill(SEL.viewImportText, "{ this is not a view }");
  await page.click(SEL.viewImportSubmit);
  const importError = await page
    .waitForFunction(
      () => Boolean(document.querySelector('[data-testid="view-import-dialog"] .add-error')),
      { timeout: 15000 }
    )
    .then(() => true)
    .catch(() => false);
  check("an invalid import document is rejected inline", importError);
  await page.locator(SEL.viewImportDialog + " button").filter({ hasText: "cancel" }).first().click();
  await page.waitForSelector(SEL.viewImportDialog, { state: "detached", timeout: 15000 }).catch(() => {});

  // A successful import must close the dialog: leaving it open invited a
  // second click that imported a duplicate view.
  const viewsForImport = await api("/api/v1/views");
  const importSource = (viewsForImport.body?.views || []).find((view) => view.kind === "graph");
  if (importSource) {
    const rowsBeforeImport = await page.locator(SEL.viewRow).count();
    await page.click(SEL.viewImport);
    await page.waitForSelector(SEL.viewImportDialog, { timeout: 15000 });
    await page.fill(
      SEL.viewImportText,
      JSON.stringify({ name: "Smoke imported view", kind: "graph", definition: importSource.definition })
    );
    await page.click(SEL.viewImportSubmit);
    const importClosed = await page
      .waitForSelector(SEL.viewImportDialog, { state: "detached", timeout: 20000 })
      .then(() => true)
      .catch(() => false);
    const rowsAfterImport = await page.locator(SEL.viewRow).count();
    check(
      "a successful import closes the dialog and adds one view",
      importClosed && rowsAfterImport === rowsBeforeImport + 1,
      JSON.stringify({ importClosed, before: rowsBeforeImport, after: rowsAfterImport })
    );
    await page.waitForFunction((selector) => [...document.querySelectorAll(selector)].some((row) => (row.textContent || "").includes("Smoke imported view")), SEL.viewRow, { timeout: 20000 }).catch(() => {});
    check("the imported view is listed", (await rowByName("Smoke imported view").count()) === 1);
  } else {
    check("a graph view is available to import", false, JSON.stringify(viewsForImport.body?.views?.length));
  }

  // --------------------------------------------------------- ledger view ---
  await page.click(SEL.section("ledger"));
  await page.waitForSelector(SEL.search, { timeout: 20000 });
  await page.fill(SEL.search, "bulk");
  await page.waitForTimeout(600);
  await page.click(SEL.viewSaveCurrent);
  await page.waitForSelector(SEL.viewSaveDialog, { timeout: 15000 });
  await page.fill(SEL.viewNameInput, "Smoke ledger view");
  await page.click(SEL.viewSaveSubmit);
  await page.waitForSelector(SEL.viewSaveDialog, { state: "detached", timeout: 20000 }).catch(() => {});
  const viewsAfterLedger = await api("/api/v1/views");
  const ledgerView = (viewsAfterLedger.body?.views || []).find((view) => view.name === "Smoke ledger view");
  check(
    "the ledger save captures the query",
    Boolean(ledgerView) && ledgerView.kind === "ledger" && ledgerView.definition?.query === "bulk",
    JSON.stringify(ledgerView)
  );
  await page.click(SEL.section("views"));
  await waitForRows();
  await rowByName("Smoke ledger view").locator(SEL.viewOpen).click();
  check("opening a ledger view lands on the ledger", (await waitForPath("/")) === "/", page.url());
  await page.waitForFunction((selector) => document.querySelector(selector)?.value === "bulk", SEL.search, { timeout: 20000 }).catch(() => {});
  check("the ledger view applies its query", (await page.locator(SEL.search).inputValue()) === "bulk", await page.locator(SEL.search).inputValue());

  // ------------------------------------------------------------ drag budget ---
  await page.goto(BASE + "/graph", { waitUntil: "domcontentloaded" });
  await waitForGraph();
  check("the saved group is active before the drag", await waitForRedPixels(), JSON.stringify(await canvasCounts()));
  const box = await page.locator(SEL.graphCanvas).boundingBox();
  const drag = box
    ? await framesDuring(async () => {
        const centreX = box.x + box.width / 2;
        const centreY = box.y + box.height / 2;
        await page.mouse.move(centreX, centreY);
        await page.mouse.down();
        for (let index = 1; index <= 80; index += 1) {
          await page.mouse.move(centreX + Math.sin(index / 9) * 160, centreY + Math.cos(index / 11) * 100);
        }
        await page.mouse.up();
      })
    : { count: 0, p50: Number.NaN, p95: Number.NaN };
  console.log("drag frames: " + JSON.stringify(drag));
  check("drag frames stay inside the graph budget", drag.count > 0 && drag.p95 <= DRAG_BUDGET_MS, JSON.stringify(drag));

  // ------------------------------------------------------- console noise ---
  const unexpected = errors.filter((entry) => !/400|401/.test(entry));
  check("no unexpected console errors", unexpected.length === 0, unexpected.slice(0, 3).join(" | ").slice(0, 400));
} catch (error) {
  check("unexpected error", false, String(error && error.stack ? error.stack : error));
} finally {
  await browser.close();
}

report(errors);
