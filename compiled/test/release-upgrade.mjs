// Usage: node compiled/test/release-upgrade.mjs OLD_DIST NEW_DIST [PAGE_PATH]
// Supply two releases of one consumer app with a newer, non-idempotent schema
// migration in NEW_DIST. This server and browser profile exist only for the test.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, resolve, sep } from "node:path";
import { chromium } from "../bench/env.mjs";

const [oldDist, newDist, pagePath = "/"] = process.argv.slice(2);
if (!oldDist || !newDist) throw new Error("Supply an old and a new compiled site directory");
let root = resolve(oldDist);
const types = { ".js": "text/javascript", ".wasm": "application/wasm", ".json": "application/json", ".html": "text/html" };
const server = createServer(async (req, res) => {
  const path = new URL(req.url, "http://localhost").pathname;
  const file = resolve(root, "." + (path === pagePath ? "/index.html" : path));
  try {
    if (!file.startsWith(root + sep)) throw new Error("Invalid path");
    const contents = await readFile(file);
    res.writeHead(200, { "Content-Type": types[extname(file)] || "application/octet-stream", "Cache-Control": "no-store" });
    res.end(contents);
  } catch { res.writeHead(404).end(); }
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
let browser;
try {
  browser = await chromium.launch({ channel: "chrome" });
  const context = await browser.newContext();
  await context.addInitScript(() => sessionStorage.setItem("instant_record.inspector", JSON.stringify({ offline: true })));
  const page = await context.newPage();
  const url = "http://127.0.0.1:" + server.address().port + pagePath;

  // Hash the actual saved image. An unsuccessful boot must leave both the
  // image and its revision untouched, including changes still in the outbox.
  async function snapshot(setVersion) {
    return page.evaluate(async version => {
      const db = await new Promise((resolve, reject) => {
        const request = indexedDB.open("instant-record-spinel", 3);
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error);
      });
      try {
        const tx = db.transaction("files", version == null ? "readonly" : "readwrite");
        const store = tx.objectStore("files");
        if (version != null) store.put(version, "rails_schema_version");
        const requests = ["development.sqlite3", "snapshot_revision", "rails_schema_version"].map(key => store.get(key));
        await new Promise((resolve, reject) => {
          tx.oncomplete = resolve;
          tx.onabort = () => reject(tx.error);
        });
        const [idbBytes, revision, savedVersion] = requests.map(request => request.result);
        let bytes = idbBytes;
        if (!bytes && navigator.storage?.getDirectory) {
          const root = await navigator.storage.getDirectory();
          const appDir = await root.getDirectoryHandle("instant-record-spinel");
          const scopeDir = await appDir.getDirectoryHandle("default");
          const fileHandle = await scopeDir.getFileHandle("development.sqlite3");
          bytes = new Uint8Array(await (await fileHandle.getFile()).arrayBuffer());
        }
        const hash = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))];
        return { hash, revision, version: savedVersion };
      } finally { db.close(); }
    }, setVersion);
  }

  await page.goto(url);
  await page.waitForFunction(() => window.__spinel?.marks.rendered);
  const old = await snapshot();
  root = resolve(newDist);
  await page.evaluate(() => window.dispatchEvent(new Event("focus")));
  await page.waitForFunction(version => window.__spinel?.marks.rendered && window.__spinel.sourceVersion !== version,
    JSON.parse(await readFile(resolve(oldDist, "instant-record-release.json"), "utf8")).version.slice(0, 12));
  const upgraded = await snapshot();
  assert.ok(upgraded.version > old.version);
  assert.ok(upgraded.revision > old.revision);
  await page.reload();
  await page.waitForFunction(() => window.__spinel?.marks.rendered);
  assert.deepEqual(await snapshot(), upgraded);

  // Rolling back to an older release auto-rehydrates onto old.version cleanly
  // (extracting and preserving any pending outbox rows) instead of white-screening.
  root = resolve(oldDist);
  await page.reload();
  await page.waitForFunction(() => window.__spinel?.marks.rendered);
  const rolledBack = await snapshot();
  assert.equal(rolledBack.version, old.version);
  assert.ok(rolledBack.revision > upgraded.revision);

  // Simulate a legacy image whose declared version is older than its actual
  // tables. Reapplying the fixture's ALTER TABLE fails atomically and triggers
  // outbox-preserving auto-rehydration onto newDist's clean schema.
  root = resolve(newDist);
  await page.reload();
  await page.waitForFunction(() => window.__spinel?.marks.rendered);
  const reUpgraded = await snapshot();
  assert.equal(reUpgraded.version, upgraded.version);

  const inconsistent = await snapshot(old.version);
  await page.reload();
  await page.waitForFunction(() => window.__spinel?.marks.rendered);
  const selfHealed = await snapshot();
  assert.equal(selfHealed.version, upgraded.version);
  assert.ok(selfHealed.revision > inconsistent.revision);
  console.log("PASS open-tab upgrade, idempotent restart, rollback auto-rehydration, failed migration self-heal");
} finally {
  await browser?.close();
  server.close();
}
