// Usage: node compiled/test/shell-worker.mjs
// The service worker across a release, with no compiled build: a small server
// stands in for the site and serves the worker the demo ships. It answers
// scripts as the deployed site does, cacheable for an hour.
//
// A page is fetched from the network, so it is the new release's at once. A
// script it names has to be that release's too, or the new page runs the old
// script: the Inbox's page was held unpainted for four seconds that way, since
// its stylesheet waited on a signal only the new script gives.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const worker = await readFile(fileURLToPath(new URL("../../demo/app/views/pwa/service-worker.js", import.meta.url)));
// The toolchain's Playwright where a compiled build is set up, or else the machine's own.
const { chromium } = await import("../bench/env.mjs").catch(() => createRequire(import.meta.url)("playwright"));

let release = 1;
let named = false;
const asked = new Map();
const script = () => "/assets/inbox.js" + (named ? "?v=" + release : "");
// What the demo's application.js does: register the worker and name what loaded.
const page = () => `<!doctype html><title>Release</title><script src="${script()}"></script><script>
  navigator.serviceWorker.register("/service-worker.js").then(() => navigator.serviceWorker.ready).then((registration) => {
    registration.active.postMessage({ type: "instant_record.precache",
      urls: performance.getEntriesByType("resource").map((entry) => entry.name), page: location.pathname });
  });
</script>`;
const server = createServer((req, res) => {
  const url = new URL(req.url, "http://localhost");
  asked.set(url.pathname + url.search, (asked.get(url.pathname + url.search) || 0) + 1);
  if (url.pathname === "/service-worker.js") return res.writeHead(200, { "Content-Type": "text/javascript" }).end(worker);
  if (url.pathname === "/assets/inbox.js") {
    // A script named after its content keeps that content whatever release the server is on.
    const body = "window.release = " + (url.searchParams.get("v") || release);
    return res.writeHead(200, { "Content-Type": "text/javascript", "Cache-Control": "public, max-age=3600" }).end(body);
  }
  if (url.pathname === "/") return res.writeHead(200, { "Content-Type": "text/html" }).end(page());
  res.writeHead(404).end();
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const origin = "http://127.0.0.1:" + server.address().port;

const browser = await chromium.launch({ channel: "chrome" }).catch(() => chromium.launch());
try {
  // A visit in a new tab, not a reload: a page answers a script it has run from its own
  // memory, and the worker is never asked.
  const visit = async tab => {
    const next = await tab.context().newPage();
    await tab.close();
    await next.goto(origin);
    return next;
  };
  // A browser that has opened the site: the worker controls the page and keeps its script.
  const visitor = async () => {
    const context = await browser.newContext();
    const tab = await context.newPage();
    await tab.goto(origin);
    await tab.evaluate(() => navigator.serviceWorker.ready);
    await until(() => kept(tab), text => text !== null);
    const next = await visit(tab);
    await next.waitForFunction(() => !!navigator.serviceWorker.controller);
    return next;
  };
  const running = tab => tab.evaluate(() => window.release);
  // The script as the worker holds it, or null.
  const kept = tab => tab.evaluate(async address => (await caches.match(address))?.text() ?? null, origin + script());
  const until = async (read, done) => {
    for (let tries = 0; tries < 100; tries++) {
      if (done(await read())) return;
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    throw new Error("Timed out waiting on the worker's cache");
  };

  // 1. A script named after its content: the page of a new release runs that release's script
  //    on its first load, and a script the worker holds is not asked for again.
  named = true;
  let tab = await visitor();
  assert.equal(await running(tab), 1);
  release = 2;
  tab = await visit(tab);
  assert.equal(await running(tab), 2, "the first load after a release runs the new release's script");
  tab = await visit(tab);
  tab = await visit(tab);
  assert.equal(asked.get("/assets/inbox.js?v=2"), 1, "a script named after its content is fetched once");
  await tab.context().close();

  // 2. A script with one name for every release is answered from the cache and refreshed
  //    behind the answer. The refresh has to reach the server: the copy the browser's own
  //    cache still holds is the old release's, and would be kept as the new one.
  named = false;
  release = 3;
  tab = await visitor();
  assert.equal(await running(tab), 3);
  release = 4;
  const before = asked.get("/assets/inbox.js");
  tab = await visit(tab);
  await until(() => asked.get("/assets/inbox.js"), count => count > before)
    .catch(() => assert.fail("the refresh behind the answer asks the server, not the browser's cache"));
  await until(() => kept(tab), text => text.endsWith("4"));
  tab = await visit(tab);
  assert.equal(await running(tab), 4, "the load after the refresh runs the new release's script");
  console.log("shell worker: a release's page runs that release's scripts");
} finally {
  await browser.close();
  server.close();
}
