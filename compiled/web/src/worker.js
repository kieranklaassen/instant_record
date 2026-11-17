// Dedicated worker (hand-written): owns the compiled app, its in-memory filesystem and the sync
// timer. A worker, not a service worker, because the gem's sync transport needs a synchronous
// HTTP call from inside a wasm run, and synchronous XHR only exists in dedicated workers.
import { AppHost } from "./app-host.js";

const SYNC_ENDPOINT = import.meta.env.VITE_SYNC_ENDPOINT || "/instant_record";
const SYNC_EVERY_MS = 1000;

function exchange(method, url, body) {
  const xhr = new XMLHttpRequest();
  xhr.open(method, url, false); // synchronous on purpose
  if (method === "POST") xhr.setRequestHeader("Content-Type", "application/json");
  xhr.send(method === "POST" ? body : null);
  return { status: xhr.status, body: xhr.responseText };
}

// ── persistence: the SQLite file and the app secret live in IndexedDB between page loads ──
function idb() {
  return new Promise((resolve, reject) => {
    const open = indexedDB.open("instant-record-spinel", 1);
    open.onupgradeneeded = () => open.result.createObjectStore("files");
    open.onsuccess = () => resolve(open.result);
    open.onerror = () => reject(open.error);
  });
}
async function load(key) {
  const db = await idb();
  return new Promise((resolve, reject) => {
    const get = db.transaction("files").objectStore("files").get(key);
    get.onsuccess = () => resolve(get.result ?? null);
    get.onerror = () => reject(get.error);
  });
}
async function store(key, value) {
  const db = await idb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction("files", "readwrite");
    tx.objectStore("files").put(value, key);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

let host = null;
let saveTimer = null;
function scheduleSave() {
  if (saveTimer) return;
  saveTimer = setTimeout(async () => {
    saveTimer = null;
    const bytes = host.databaseBytes();
    if (bytes) await store("development.sqlite3", bytes.slice());
  }, 200);
}

// A write should reach the server soon, but not ahead of the page's own next request: the page
// that just posted asks for its refreshed view straight away, and a sync pass started first would
// make it wait behind a wasm run and an HTTP round trip. So the pass a write asks for starts once
// the worker has been quiet for a moment.
const QUIET_MS = 30;
let kickTimer = null;
function kickSync() {
  clearTimeout(kickTimer);
  kickTimer = setTimeout(syncPass, QUIET_MS);
}

async function syncPass() {
  clearTimeout(kickTimer);
  kickTimer = null;
  const result = host.sync(SYNC_ENDPOINT);
  if (result.changed || result.notified) {
    // Save before telling the tab: a page without an in-place refresh reloads on this message,
    // and the reloaded page must find the rows that were just applied.
    const bytes = host.databaseBytes();
    if (bytes) await store("development.sqlite3", bytes.slice());
  }
  if (result.notified) self.postMessage({ type: "records_changed" });
  return result;
}

// Start reading what an earlier visit saved as soon as the worker exists, not when the boot
// message arrives.
const saved = Promise.all([load("development.sqlite3"), load("secret_key_base")]);

// One page request through the app, following its redirects here so the page gets the final
// answer in one round trip.
function navigate({ method, path, body, contentType }) {
  const started = performance.now();
  let result = host.request(method, path, { body: body ?? "", contentType: contentType || "application/x-www-form-urlencoded" });
  let redirected = false;
  let finalPath = path;
  for (let hops = 0; hops < 5 && result.status >= 300 && result.status < 400; hops++) {
    const location = result.headers.find(([name]) => name.toLowerCase() === "location")?.[1];
    if (!location) break;
    const next = new URL(location, self.location.origin);
    finalPath = next.pathname + next.search;
    redirected = true;
    result = host.request("GET", finalPath);
  }
  if (method !== "GET") {
    scheduleSave();
    kickSync(); // a local write: push it up as soon as the page has what it asked for
  } else if (kickTimer) {
    kickSync(); // still busy with the page: keep the pending pass behind it
  }
  return { result: { ...result, ms: performance.now() - started }, redirected, finalPath };
}

async function boot(payload = {}) {
  const started = performance.now();
  // The shell starts compiling the module itself and passes it in; compile here only if it did not.
  const [module, [savedDatabase, savedSecret]] = await Promise.all([
    payload.module || WebAssembly.compileStreaming(fetch(import.meta.env.VITE_WASM_URL || "/app.wasm")),
    saved,
  ]);
  const compiled = performance.now();
  const secret = savedSecret || [...crypto.getRandomValues(new Uint8Array(64))].map((b) => b.toString(16).padStart(2, "0")).join("");
  if (!savedSecret) await store("secret_key_base", secret);
  host = new AppHost(module, { exchange, env: { SECRET_KEY_BASE: secret } });
  if (savedDatabase) {
    host.restoreDatabase(savedDatabase);
  } else {
    // First visit: nothing local to show yet. Take the server's snapshot now, before the first
    // page is rendered, instead of rendering an empty page, waiting for the sync timer and
    // reloading. If the server cannot be reached the pass fails fast and the page renders empty.
    const first = host.sync(SYNC_ENDPOINT);
    if (first.changed) scheduleSave();
  }
  setInterval(syncPass, SYNC_EVERY_MS);
  // Answer the page's first request in the same round trip as the boot.
  const first = payload.path ? navigate({ method: "GET", path: payload.path }) : null;
  return { compileMs: compiled - started, restored: !!savedDatabase, first };
}

self.onmessage = async (event) => {
  const { id, type, payload } = event.data;
  try {
    if (type === "boot") return self.postMessage({ id, result: await boot(payload) });
    if (type === "navigate") return self.postMessage({ id, result: navigate(payload) });
    if (type === "request") {
      // A single request with no redirect following, for callers that asked for redirect: "manual".
      const started = performance.now();
      const result = host.request(payload.method, payload.path, { body: payload.body ?? "", contentType: payload.contentType || "application/x-www-form-urlencoded" });
      if (payload.method !== "GET") {
        scheduleSave();
        kickSync();
      } else if (kickTimer) {
        kickSync();
      }
      return self.postMessage({ id, result: { ...result, ms: performance.now() - started } });
    }
    if (type === "sync") return self.postMessage({ id, result: await syncPass() });
  } catch (error) {
    self.postMessage({ id, error: String(error && error.message ? error.message : error) });
  }
};
