// Dedicated worker: owns the persistent WASI reactor app, a cached IndexedDB handle,
// retry-only outbox draining, and non-blocking async change polling (window=0, so the
// worker never blocks on network I/O during user clicks and Puma threads are never held).
import { AppHost } from "./app-host.js";

const SYNC_ENDPOINT = import.meta.env.VITE_SYNC_ENDPOINT || "/instant_record";
const POLL_EVERY_MS = 1000;
const QUIET_MS = 30;
const DRAIN_RETRY_BASE_MS = 500;
const DRAIN_RETRY_CAP_MS = 10000;

let simulation = { offline: false, latencyMs: 0, report: false };
const history = [];

function report(entry) {
  const stamped = { ...entry, at: Date.now() };
  history.push(stamped);
  if (history.length > 150) history.shift();
  if (simulation.report) self.postMessage({ type: "instant_record.debug", entry: stamped });
}

async function fetchReply(method, path, body = "") {
  const url = SYNC_ENDPOINT + path;
  const started = performance.now();
  const poll = path.startsWith("/events?");
  let status = 0;
  let text = "";
  let outcome = "failed";
  try {
    if (simulation.latencyMs && !simulation.offline) {
      await new Promise(resolve => setTimeout(resolve, simulation.latencyMs));
    }
    if (simulation.offline) {
      outcome = "offline";
      return { method, url, body, status, text };
    }
    const options = { method, signal: AbortSignal.timeout(30000) };
    if (method === "POST") {
      options.headers = { "Content-Type": "application/json" };
      options.body = body;
    }
    const response = await fetch(url, options);
    text = await response.text();
    outcome = status = response.status;
  } catch {
    // A failed exchange stays in the durable outbox for retry.
  } finally {
    // Empty successful catch-up polls would bury the actions being inspected.
    if (!poll || status !== 200 || text.trim()) {
      report({ kind: poll ? "stream" : "sync", method, path: new URL(url, self.location.origin).pathname,
        status: outcome, ms: Math.round(performance.now() - started) });
    }
  }
  return { method, url, body, status, text };
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
async function loadMany(keys) {
  const db = await idb();
  return new Promise((resolve, reject) => {
    const store = db.transaction("files").objectStore("files");
    const out = new Array(keys.length);
    let remaining = keys.length;
    keys.forEach((key, index) => {
      const req = store.get(key);
      req.onsuccess = () => {
        out[index] = req.result ?? null;
        if (--remaining === 0) resolve(out);
      };
      req.onerror = () => reject(req.error);
    });
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
let draining = null;
let localRevision = 0;
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

function syncPass() {
  clearTimeout(kickTimer);
  kickTimer = null;
  if (!draining) {
    const revision = localRevision;
    draining = drain(revision).finally(() => {
      draining = null;
      if (revision !== localRevision) kickSync();
    });
  }
  return draining;
}

async function drain(revision, initial = false) {
  const plan = host.syncPlan();
  const push = plan.push ? await fetchReply("POST", "/mutations", plan.push) : null;
  const snapshot = plan.bootstrap ? await fetchReply("GET", "/bootstrap") : null;

  // An edit made during the network wait takes precedence over an old rejection or
  // snapshot. Retry from SQLite with the original mutation IDs for idempotent replay.
  if (revision !== localRevision) return { changed: false, retried: true };
  const result = host.sync(SYNC_ENDPOINT, (method, url, body) => {
    const reply = method === "POST" ? push : snapshot;
    if (!reply || reply.method !== method || reply.url !== url || reply.body !== body) {
      throw new Error("Unexpected request while applying prepared sync responses");
    }
    return { status: reply.status, body: reply.text };
  });
  const needsBootstrap = plan.bootstrap && !host.syncState().bootstrapped;
  if (push || snapshot) report({ kind: "sync-pass", path: `${result.pending} pending` });
  currentCursor = needsBootstrap ? null : result.cursor;
  if (result.changed || result.notified) {
    if (initial) {
      scheduleSave(); // The first page already renders the snapshot.
    } else {
      await persistDatabaseNow();
      if (result.notified) self.postMessage({ type: "records_changed" });
    }
  }

  if (result.pending > 0 || needsBootstrap) {
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
  if (!host || pollInFlight || draining || kickTimer) return;
  const revision = localRevision;
  pollInFlight = true;
  try {
    if (currentCursor === null) {
      const state = host.syncState();
      if (state.pending > 0 || !state.bootstrapped) {
        kickSync(0);
        return;
      }
      currentCursor = state.cursor;
    }
    const { status, text } = await fetchReply("GET", `/events?after=${currentCursor}&window=0`);
    if (status !== 200) return;
    if (!text.trim() || draining || kickTimer || revision !== localRevision) return;

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

const saved = loadMany(["development.sqlite3", "secret_key_base"]);

function afterRequest(method) {
  if (method === "GET" || method === "HEAD") return;
  localRevision++;
  scheduleSave();
  drainDelayMs = DRAIN_RETRY_BASE_MS;
  kickSync();
}

function localRequest(method, path, options) {
  const started = performance.now();
  const result = host.request(method, path, options);
  report({ kind: "local", method, path, status: result.status, ms: Math.round(performance.now() - started) });
  return result;
}

function navigate({ method, path, body, contentType }) {
  const started = performance.now();
  let result = localRequest(method, path, { body: body ?? "", contentType: contentType || "application/x-www-form-urlencoded" });
  let redirected = false;
  let finalPath = path;
  for (let hops = 0; hops < 5 && result.status >= 300 && result.status < 400; hops++) {
    const location = result.headers.find(([name]) => name.toLowerCase() === "location")?.[1];
    if (!location) break;
    const next = new URL(location, self.location.origin);
    finalPath = next.pathname + next.search;
    redirected = true;
    result = localRequest("GET", finalPath);
  }
  afterRequest(method);
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

  host = new AppHost(module, { env: { SECRET_KEY_BASE: secret } });
  if (savedDatabase) {
    host.restoreDatabase(savedDatabase);
  } else {
    await drain(localRevision, true);
  }

  const first = payload.path ? navigate({ method: "GET", path: payload.path }) : null;
  setInterval(pollChanges, POLL_EVERY_MS);
  return { compileMs: compiled - started, restored: !!savedDatabase, first };
}

self.onmessage = async (event) => {
  const { id, type, payload } = event.data;
  try {
    if (type === "instant_record.clear_log") {
      history.length = 0;
      return;
    }
    if (type === "instant_record.simulate") {
      const previous = simulation;
      simulation = event.data.settings;
      if (event.data.backlog) {
        self.postMessage({ type: "instant_record.debug_backlog", entries: history, streamOpen: false });
      }
      if (host && previous.offline && !simulation.offline) {
        drainDelayMs = DRAIN_RETRY_BASE_MS;
        kickSync(0);
      }
      return;
    }
    if (type === "boot") return self.postMessage({ id, result: await boot(payload) });
    if (type === "navigate") return self.postMessage({ id, result: navigate(payload) });
    if (type === "request") {
      const started = performance.now();
      const result = localRequest(payload.method, payload.path, { body: payload.body ?? "", contentType: payload.contentType || "application/x-www-form-urlencoded" });
      afterRequest(payload.method);
      return self.postMessage({ id, result: { ...result, ms: performance.now() - started } });
    }
    if (type === "sync") return self.postMessage({ id, result: await syncPass() });
  } catch (error) {
    self.postMessage({ id, error: String(error && error.message ? error.message : error) });
  }
};
