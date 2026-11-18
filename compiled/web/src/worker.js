// Dedicated worker: owns the persistent WASI reactor app, a cached IndexedDB handle,
// retry-only outbox draining, and non-blocking async change polling (window=0, so the
// worker never blocks on network I/O during user clicks and Puma threads are never held).
import { AppHost } from "./app-host.js";

const SYNC_ENDPOINT = import.meta.env.VITE_SYNC_ENDPOINT || "/instant_record";
const POLL_EVERY_MS = 1000;
const QUIET_MS = 30;
const DRAIN_RETRY_BASE_MS = 500;
const DRAIN_RETRY_CAP_MS = 10000;

function exchange(method, url, body) {
  const xhr = new XMLHttpRequest();
  xhr.open(method, url, false); // synchronous on purpose (used only for bootstrap & outbox drain)
  if (method === "POST") xhr.setRequestHeader("Content-Type", "application/json");
  xhr.send(method === "POST" ? body : null);
  return { status: xhr.status, body: xhr.responseText };
}

// ── persistence: single cached IndexedDB handle ──
let dbPromise = null;
function idb() {
  return (dbPromise ||= new Promise((resolve, reject) => {
    const open = indexedDB.open("instant-record-spinel", 1);
    open.onupgradeneeded = () => open.result.createObjectStore("files");
    open.onsuccess = () => resolve(open.result);
    open.onerror = () => reject(open.error);
  }));
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
let currentCursor = null;
let saveTimer = null;
let kickTimer = null;
let pollInFlight = false;
let drainDelayMs = DRAIN_RETRY_BASE_MS;

async function persistDatabaseNow() {
  clearTimeout(saveTimer);
  saveTimer = null;
  const bytes = host?.databaseBytes();
  if (bytes) await store("development.sqlite3", bytes.slice());
}

function scheduleSave() {
  if (saveTimer) return;
  saveTimer = setTimeout(() => {
    saveTimer = null;
    persistDatabaseNow();
  }, 200);
}

function kickSync(delay = QUIET_MS) {
  clearTimeout(kickTimer);
  kickTimer = setTimeout(syncPass, delay);
}

async function syncPass() {
  clearTimeout(kickTimer);
  kickTimer = null;
  if (!host) return null;

  const result = host.sync(SYNC_ENDPOINT);
  currentCursor = result.cursor;
  if (result.changed || result.notified) {
    await persistDatabaseNow();
  }
  if (result.notified) self.postMessage({ type: "records_changed" });

  if (result.pending > 0) {
    kickSync(drainDelayMs);
    drainDelayMs = Math.min(drainDelayMs * 2, DRAIN_RETRY_CAP_MS);
  } else {
    drainDelayMs = DRAIN_RETRY_BASE_MS;
  }
  return result;
}

// Non-blocking catch-up poll: window=0 returns immediately (zero held server threads),
// async fetch keeps the worker event loop unblocked for user clicks, and an empty body
// skips Wasm entirely.
async function pollChanges() {
  if (!host || pollInFlight) return;
  pollInFlight = true;
  try {
    if (currentCursor === null) currentCursor = host.cursor();
    const response = await fetch(`${SYNC_ENDPOINT}/events?after=${currentCursor}&window=0`);
    if (!response.ok) return;
    const text = await response.text();
    if (!text.trim()) return;

    const consumed = host.consumeStream(text);
    currentCursor = consumed.cursor;
    if (consumed.applied > 0 || consumed.notified) {
      await persistDatabaseNow();
      self.postMessage({ type: "records_changed" });
    }
  } catch {
    // offline: try again on the next interval
  } finally {
    pollInFlight = false;
  }
}

const saved = Promise.all([load("development.sqlite3"), load("secret_key_base")]);

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
    drainDelayMs = DRAIN_RETRY_BASE_MS;
    kickSync(QUIET_MS);
  } else if (kickTimer) {
    kickSync(QUIET_MS);
  }
  return { result: { ...result, ms: performance.now() - started }, redirected, finalPath };
}

async function boot(payload = {}) {
  const started = performance.now();
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
    const first = host.sync(SYNC_ENDPOINT);
    currentCursor = first.cursor;
    if (first.changed) scheduleSave();
  }

  const first = payload.path ? navigate({ method: "GET", path: payload.path }) : null;
  setInterval(pollChanges, POLL_EVERY_MS);
  return { compileMs: compiled - started, restored: !!savedDatabase, first };
}

self.onmessage = async (event) => {
  const { id, type, payload } = event.data;
  try {
    if (type === "boot") return self.postMessage({ id, result: await boot(payload) });
    if (type === "navigate") return self.postMessage({ id, result: navigate(payload) });
    if (type === "request") {
      const started = performance.now();
      const result = host.request(payload.method, payload.path, { body: payload.body ?? "", contentType: payload.contentType || "application/x-www-form-urlencoded" });
      if (payload.method !== "GET") {
        scheduleSave();
        drainDelayMs = DRAIN_RETRY_BASE_MS;
        kickSync(QUIET_MS);
      } else if (kickTimer) {
        kickSync(QUIET_MS);
      }
      return self.postMessage({ id, result: { ...result, ms: performance.now() - started } });
    }
    if (type === "sync") return self.postMessage({ id, result: await syncPass() });
  } catch (error) {
    self.postMessage({ id, error: String(error && error.message ? error.message : error) });
  }
};
