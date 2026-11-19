// Dedicated worker: owns the persistent WASI reactor app, a cached IndexedDB handle,
// retry-only outbox draining, and non-blocking async change polling (window=0, so the
// worker never blocks on network I/O during user clicks and Puma threads are never held).
import { AppHost } from "./app-host.js";
import { mailboxScope } from "./mailbox-scope.js";
import { openSnapshot, withFiles } from "./snapshot-store.js";

const publicEndpoint = import.meta.env.VITE_SYNC_ENDPOINT || "/instant_record";
let syncEndpoint = publicEndpoint;
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

async function fetchReply(method, path, body = "", endpoint = syncEndpoint) {
  const url = endpoint + path;
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

const DATABASE = "development.sqlite3";
const REVISION = "snapshot_revision";
const SCHEMA = "rails_schema_version";
const targetSchema = Number(import.meta.env.VITE_SCHEMA_VERSION);
const legacySchema = import.meta.env.VITE_SCHEMA_BASELINE;
const migrationHistory = JSON.parse(import.meta.env.VITE_MIGRATION_HISTORY);
const schemaDigest = import.meta.env.VITE_SCHEMA_DIGEST;
let snapshotRevision;
let changes;

let host = null;
let currentCursor = null;
let kickTimer = null;
let pollInFlight = false;
let draining = null;
let localRevision = 0;
let drainDelayMs = DRAIN_RETRY_BASE_MS;

// Keep each tab's hot reactor until a peer changes the durable revision.
async function withSnapshot(mode, operation) {
  let wrote = false;
  try {
    const result = await withFiles(mode, async (get, put) => {
      const revision = await get(REVISION);
      if (revision !== snapshotRevision) {
        if ((await get(SCHEMA)) !== targetSchema) {
          self.postMessage({ type: "release_required" });
          throw new Error("A newer Rails release migrated this database. Reload to continue.");
        }
        const bytes = await get(DATABASE);
        const previous = host;
        const restored = new AppHost(previous.module, { env: previous.env });
        restored.cookies = previous.cookies;
        if (bytes) restored.restoreDatabase(bytes, targetSchema);
        restored.ensureBooted();
        host = restored;
        snapshotRevision = revision;
        localRevision++;
        currentCursor = null;
      }
      return operation(() => {
        const bytes = host.databaseBytes();
        if (!bytes) throw new Error("SQLite did not produce a database snapshot");
        snapshotRevision = (revision ?? 0) + 1;
        put(DATABASE, bytes);
        put(REVISION, snapshotRevision);
        wrote = true;
      });
    });
    if (wrote) changes.postMessage(snapshotRevision);
    return result;
  } catch (error) {
    // Discard uncommitted in-memory changes before the next operation.
    snapshotRevision = Symbol("reload");
    throw error;
  }
}

function kickSync(delay = QUIET_MS) {
  clearTimeout(kickTimer);
  kickTimer = setTimeout(syncPass, delay);
}

// The connection came back: send what is waiting now, not at the next retry.
self.addEventListener("online", () => kickSync(0));

function syncPass() {
  clearTimeout(kickTimer);
  kickTimer = null;
  if (!draining) {
    const revision = localRevision;
    draining = drain().finally(() => {
      draining = null;
      if (revision !== localRevision) kickSync();
    });
  }
  return draining;
}

async function drain(initial = false) {
  const { plan, revision } = await withSnapshot("readonly", () => ({ plan: host.syncPlan(), revision: snapshotRevision }));
  const push = plan.push ? await fetchReply("POST", "/mutations", plan.push) : null;
  const snapshot = plan.bootstrap ? await fetchReply("GET", "/bootstrap") : null;

  // An edit made during the network wait takes precedence over an old rejection or
  // snapshot. Retry from SQLite with the original mutation IDs for idempotent replay.
  const result = await withSnapshot("readwrite", save => {
    if (revision !== snapshotRevision) {
      kickSync();
      return { changed: false, retried: true };
    }
    const result = host.sync(syncEndpoint, (method, url, body) => {
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
      save();
    }

    if (result.pending > 0 || needsBootstrap) {
      kickSync(drainDelayMs);
      drainDelayMs = Math.min(drainDelayMs * 2, DRAIN_RETRY_CAP_MS);
    } else {
      drainDelayMs = DRAIN_RETRY_BASE_MS;
    }
    return result;
  });
  if (!initial && result.notified) self.postMessage({ type: "records_changed" });
  return result;
}

// Non-blocking catch-up poll: window=0 returns immediately (zero held server threads),
// async fetch keeps the worker event loop unblocked for user clicks, and an empty body
// skips Wasm entirely.
async function pollChanges() {
  if (!host || pollInFlight || draining || kickTimer) return;
  const revision = snapshotRevision;
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
    if (!text.trim() || draining || kickTimer || revision !== snapshotRevision) return;

    const changed = await withSnapshot("readwrite", save => {
      if (draining || kickTimer || revision !== snapshotRevision) return;
      const consumed = host.consumeStream(text);
      currentCursor = consumed.cursor;
      if (consumed.applied > 0 || consumed.notified) {
        save();
        return true;
      }
    });
    if (changed) self.postMessage({ type: "records_changed" });
  } catch {
    // offline: try again on the next interval
  } finally {
    pollInFlight = false;
  }
}

async function loadHistory(request) {
  const query = new URLSearchParams({ type: request.type, before_created_at: request.before.created_at,
    before_id: request.before.id, limit: String(request.limit) });
  if (request.partition != null) query.set("partition", request.partition);
  const key = query.toString();
  return loadHistoryQuery(key);
}

async function loadHistoryQuery(key) {
  const local = await withSnapshot("readonly", () => host.history(key));
  if (local.ok) return local;
  const revision = snapshotRevision;
  const reply = await fetchReply("GET", "/records?" + key);
  if (reply.status !== 200) return { ok: false, error: "History unavailable" };
  return withSnapshot("readwrite", save => {
    if (revision !== snapshotRevision) return { ok: false, busy: true };
    const result = host.history(key, reply.text);
    save();
    return result;
  });
}

function runRequest(method, render) {
  const writing = method !== "GET" && method !== "HEAD";
  return withSnapshot(writing ? "readwrite" : "readonly", save => {
    const result = render();
    if (writing) {
      localRevision++;
      save();
      drainDelayMs = DRAIN_RETRY_BASE_MS;
      kickSync();
    }
    return result;
  });
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
  return { result: { ...result, ms: performance.now() - started }, redirected, finalPath };
}

async function boot(payload = {}) {
  const scope = mailboxScope(payload.path || "/");
  openSnapshot(scope);
  changes = new BroadcastChannel("instant-record-spinel-changes" + (scope ? "/" + scope : ""));
  changes.onmessage = () => { if (host) self.postMessage({ type: "records_changed" }); };
  if (scope) syncEndpoint = publicEndpoint.replace(/\/instant_record\/?$/, "") + "/email/sync/" + scope;
  const started = performance.now();
  const module = payload.module || await WebAssembly.compileStreaming(fetch(import.meta.env.VITE_WASM_URL || "/app.wasm"));
  const compiled = performance.now();
  let storageMs, runtimeMs;
  const restored = await withFiles("readwrite", async (get, put) => {
    const [bytes, version, revision, savedSecret, history, previousDigest] = await Promise.all([
      get(DATABASE), get(SCHEMA), get(REVISION), get("secret_key_base"), get("migration_history"), get("schema_digest"),
    ]);
    storageMs = performance.now() - compiled;
    if (bytes && version == null && !legacySchema) throw new Error("Set compiled_migration_baseline to the schema version of the previously deployed browser app.");
    const previous = version ?? Number(legacySchema);
    if (bytes && (previous > targetSchema || (legacySchema && previous < Number(legacySchema)))) {
      throw new Error("This release cannot migrate the saved schema version " + previous + ".");
    }
    if (history) {
      const priorVersions = new Set([...Object.keys(history), ...Object.keys(migrationHistory)]);
      for (const key of priorVersions) {
        if (Number(key) <= previous && migrationHistory[key] !== history[key]) {
          throw new Error("Published migration " + key + " changed. Add a new migration instead.");
        }
      }
    }
    if (version === targetSchema && previousDigest && previousDigest !== schemaDigest) {
      throw new Error("The compiled schema changed without a new Rails migration version.");
    }
    if (bytes && previous < targetSchema && !(targetSchema in migrationHistory)) {
      throw new Error("Missing browser migration for schema version " + targetSchema + ".");
    }
    const secret = savedSecret || [...crypto.getRandomValues(new Uint8Array(64))].map(b => b.toString(16).padStart(2, "0")).join("");
    if (!savedSecret) put("secret_key_base", secret);
    const candidate = new AppHost(module, { env: { SECRET_KEY_BASE: secret } });
    if (bytes) candidate.restoreDatabase(bytes, previous);
    const initStart = performance.now();
    candidate.ensureBooted();
    runtimeMs = performance.now() - initStart;
    snapshotRevision = revision;
    if (version !== targetSchema || !previousDigest) {
      snapshotRevision = (revision ?? 0) + 1;
      put(DATABASE, candidate.databaseBytes());
      put(REVISION, snapshotRevision);
      put(SCHEMA, targetSchema);
      put("migration_history", migrationHistory);
      put("schema_digest", schemaDigest);
    }
    host = candidate;
    return !!bytes;
  });
  const bootstrapStart = performance.now();
  if (!restored) await drain(true);
  const bootstrapMs = performance.now() - bootstrapStart;

  if (scope) {
    const url = new URL(payload.path, self.location.origin);
    for (const id of new Set([url.searchParams.get("before"), url.searchParams.get("thread")])) {
      if (id) await loadHistoryQuery(new URLSearchParams({ thread: id }).toString());
    }
    const before = url.searchParams.get("before");
    const at = url.searchParams.get("at");
    if (before && at) await loadHistory({ type: "MailEntry", before: { id: before, created_at: at }, limit: 50 });
  }
  const first = payload.path ? await runRequest("GET", () => navigate({ method: "GET", path: payload.path })) : null;
  setInterval(pollChanges, POLL_EVERY_MS);
  return { compileMs: compiled - started, restored, storageMs, runtimeMs, bootstrapMs, first };
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
    if (type === "instant_record.fetch_history") {
      const port = event.ports[0];
      try { port.postMessage(await loadHistory(event.data.request)); }
      catch (error) { port.postMessage({ ok: false, error: error.message }); }
      return;
    }
    if (type === "serverRequest") {
      const url = new URL(payload.path, self.location.origin);
      const chat = import.meta.env.VITE_SHARED_INBOX_DEMO && payload.method === "POST" && url.pathname === "/assistant/replies";
      const allowed = chat || (payload.method === "GET" && url.pathname === "/receipts/probe") ||
        (payload.method === "POST" && (url.pathname === "/slack/reset" ||
          (import.meta.env.VITE_SHARED_INBOX_DEMO && url.pathname === new URL(syncEndpoint, self.location.origin).pathname + "/incoming" &&
            url.pathname.startsWith("/email/sync/"))));
      if (!allowed) throw new Error("Unknown demo server action");
      const root = publicEndpoint.replace(/\/instant_record\/?$/, "");
      const reply = await fetchReply(payload.method, url.pathname + url.search, chat ? payload.body : "", root);
      return self.postMessage({ id, result: reply });
    }
    if (type === "boot") return self.postMessage({ id, result: await boot(payload) });
    if (type === "navigate") return self.postMessage({ id, result: await runRequest(payload.method, () => navigate(payload)) });
    if (type === "request") {
      const started = performance.now();
      const result = await runRequest(payload.method, () => localRequest(payload.method, payload.path, { body: payload.body ?? "", contentType: payload.contentType || "application/x-www-form-urlencoded" }));
      return self.postMessage({ id, result: { ...result, ms: performance.now() - started } });
    }
    if (type === "save") return self.postMessage({ id, result: await withSnapshot("readwrite", save => save()) });
    if (type === "sync") return self.postMessage({ id, result: await syncPass() });
  } catch (error) {
    self.postMessage({ id, error: String(error && error.message ? error.message : error) });
  }
};
