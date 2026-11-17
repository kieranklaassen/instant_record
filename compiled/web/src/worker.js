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

async function syncPass() {
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

async function boot() {
  const started = performance.now();
  const [module, savedDatabase, savedSecret] = await Promise.all([
    WebAssembly.compileStreaming(fetch(import.meta.env.VITE_WASM_URL || "/app.wasm")),
    load("development.sqlite3"),
    load("secret_key_base"),
  ]);
  const compiled = performance.now();
  const secret = savedSecret || [...crypto.getRandomValues(new Uint8Array(64))].map((b) => b.toString(16).padStart(2, "0")).join("");
  if (!savedSecret) await store("secret_key_base", secret);
  host = new AppHost(module, { exchange, env: { SECRET_KEY_BASE: secret } });
  if (savedDatabase) host.restoreDatabase(savedDatabase);
  setInterval(syncPass, SYNC_EVERY_MS);
  return { compileMs: compiled - started, restored: !!savedDatabase };
}

self.onmessage = async (event) => {
  const { id, type, payload } = event.data;
  try {
    if (type === "boot") return self.postMessage({ id, result: await boot() });
    if (type === "request") {
      const started = performance.now();
      const result = host.request(payload.method, payload.path, { body: payload.body ?? "", contentType: payload.contentType || "application/x-www-form-urlencoded" });
      if (payload.method !== "GET") {
        scheduleSave();
        setTimeout(syncPass, 0); // a local write: push it up right away
      }
      return self.postMessage({ id, result: { ...result, ms: performance.now() - started } });
    }
    if (type === "sync") return self.postMessage({ id, result: await syncPass() });
  } catch (error) {
    self.postMessage({ id, error: String(error && error.message ? error.message : error) });
  }
};
