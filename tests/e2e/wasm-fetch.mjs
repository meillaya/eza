import { chromium } from "@playwright/test";
const BASE = process.env.EZA_BASE || "http://localhost:8087";
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage();
page.on("response", (r) => { if (r.url().includes(".wasm")) console.log("RESP", r.status(), r.url(), r.headers()["content-type"]); });
await page.goto(BASE + "/login", { waitUntil: "networkidle" });
const viaRequest = await page.request.get(BASE + "/assets/app/app.wasm");
console.log("request:", viaRequest.status(), viaRequest.headers()["content-type"], (await viaRequest.body()).length);
const viaFetch = await page.evaluate(async () => {
  const r = await fetch("/assets/app/app.wasm");
  return { status: r.status, type: r.headers.get("content-type"), len: (await r.arrayBuffer()).byteLength };
});
console.log("fetch:", JSON.stringify(viaFetch));
const direct = await page.evaluate(async (b) => {
  const r = await fetch(b + "/assets/app/app.wasm");
  return { status: r.status, type: r.headers.get("content-type") };
}, BASE);
console.log("direct:", JSON.stringify(direct));
await browser.close();
