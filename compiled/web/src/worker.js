// Dedicated worker: owns the persistent WASI reactor app, a cached IndexedDB handle,
// retry-only outbox draining, and non-blocking async change polling (window=0, so the
// worker never blocks on network I/O during user clicks and Puma threads are never held).
import { AppHost } from "./app-host.js";
import { BranchManager } from "./branch-manager.js";
import { decodeBroadcast, encodeBroadcast, mergeReads } from "./changes.js";
import { advance, fresh, held, query } from "./history-fill.js";
import { mailboxScope } from "./mailbox-scope.js";
import { resolveServerRequest, serverRoot } from "./server-request.js";
import { openSnapshot, withFiles } from "./snapshot-store.js";

const publicEndpoint = import.meta.env.VITE_SYNC_ENDPOINT || "/instant_record";
const mountPath = import.meta.env.VITE_MOUNT_PATH || "/instant_record";
let syncEndpoint = publicEndpoint;
const POLL_EVERY_MS = 1000;
const QUIET_MS = 30;
const DRAIN_RETRY_BASE_MS = 500;
const DRAIN_RETRY_CAP_MS = 10000;

// This browser's sync scope: an unguessable token the page keeps (main.js) and every sync
// request carries, so the server can keep a scoped model's rows to the browser that owns them.
let syncScope = "";
let simulation = { offline: false, latencyMs: 0, report: false };
const history = [];

function report(entry) {
  const stamped = { ...entry, at: Date.now() };
  history.push(stamped);
  if (history.length > 150) history.shift();
  if (simulation.report) self.postMessage({ type: "instant_record.debug", entry: stamped });
}

async function fetchReply(method, path, body = "", endpoint = syncEndpoint, contentType = undefined) {
  const url = endpoint + path;
  const started = performance.now();
  const poll = path.startsWith("/events?");
  let status = 0;
  let text = "";
  let responseContentType = "";
  let outcome = "failed";
  try {
    if (simulation.latencyMs && !simulation.offline) {
      await new Promise(resolve => setTimeout(resolve, simulation.latencyMs));
    }
    if (simulation.offline) {
      outcome = "offline";
      return { method, url, body, status, text, contentType: responseContentType };
    }
    const options = { method, signal: AbortSignal.timeout(30000) };
    if (method !== "GET" && method !== "HEAD") {
      const headerType = contentType === undefined ? "application/json" : contentType;
      if (headerType) options.headers = { "Content-Type": headerType };
      options.body = body;
    }
    const scoped = syncScope ? url + (url.includes("?") ? "&" : "?") + "scope=" + encodeURIComponent(syncScope) : url;
    const response = await fetch(scoped, options);
    text = await response.text();
    responseContentType = response.headers.get("content-type") || "";
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
  return { method, url, body, status, text, contentType: responseContentType };
}

const DATABASE = "development.sqlite3";
// Where the background fill of an inbox's history has come to (history-fill.js).
const FILL = "history_fill";
const FILL_PAGE = 200;
const FILL_PAUSE_MS = 300;
const FILL_RETRY_CAP_MS = 60000;
// The database is one file, held in memory and saved whole. Past this the fill stops and
// older mail stays on the server, fetched a page at a time as it always was.
const FILL_BUDGET_BYTES = 24 * 1024 * 1024;
const REVISION = "snapshot_revision";
const SCHEMA = "rails_schema_version";
const targetSchema = Number(import.meta.env.VITE_SCHEMA_VERSION);
const legacySchema = import.meta.env.VITE_SCHEMA_BASELINE;
const migrationHistory = JSON.parse(import.meta.env.VITE_MIGRATION_HISTORY);
const schemaDigest = import.meta.env.VITE_SCHEMA_DIGEST;
// A shell is a SQLite file the server built ahead of time for a first sync. It stays off until
// a build turns it on or the page asks with ?shell=1: no compiled build has opened one yet.
const shellFingerprint = import.meta.env.VITE_SHELL_FINGERPRINT;
const shellAlways = import.meta.env.VITE_SHELL_SNAPSHOT === "1";
let snapshotRevision;
let changes;

let host = null;
let activeReads = null;
const branches = new BranchManager();
let currentCursor = null;
// Read with the cursor, and sent with each poll so the server can say when the
// person behind this browser has changed.
let currentIdentity = "";
let kickTimer = null;
let pollInFlight = false;
let draining = null;
let localRevision = 0;
let drainDelayMs = DRAIN_RETRY_BASE_MS;

// Keep each tab's hot reactor until a peer changes the durable revision.
async function withSnapshot(mode, operation) {
  let wrote = false;
  let wroteChanges = null;
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
      return operation((deltaChanges = null) => {
        const bytes = host.databaseBytes();
        if (!bytes) throw new Error("SQLite did not produce a database snapshot");
        snapshotRevision = (revision ?? 0) + 1;
        put(DATABASE, bytes);
        put(REVISION, snapshotRevision);
        wrote = true;
        wroteChanges = Array.isArray(deltaChanges) ? deltaChanges : null;
      }, put);
    });
    if (wrote) changes.postMessage(encodeBroadcast(snapshotRevision, wroteChanges));
    return result;
  } catch (error) {
    // Discard uncommitted in-memory changes before the next operation.
    snapshotRevision = Symbol("reload");
    throw error;
  }
}

function kickSync(delay = QUIET_MS) {
  if (branches.isActive()) return;
  clearTimeout(kickTimer);
  kickTimer = setTimeout(syncPass, delay);
}

// The connection came back: send what is waiting now, not at the next retry.
self.addEventListener("online", () => {
  kickSync(0);
  if (mailScope && fillState && !fillState.done && !fillState.full) scheduleFill(0);
});

function syncPass() {
  clearTimeout(kickTimer);
  kickTimer = null;
  if (branches.isActive()) return Promise.resolve({ skipped: true, reason: "branched" });
  if (!draining) {
    const revision = localRevision;
    draining = drain().finally(() => {
      draining = null;
      if (revision !== localRevision) kickSync();
    });
  }
  return draining;
}

// `early` is a bootstrap asked for before the app was up (earlyBootstrap). One that did not
// arrive is asked for again here.
async function drain(initial = false, early = null) {
  if (branches.isActive()) return { changed: false, skipped: true };
  const { plan, revision } = await withSnapshot("readonly", () => ({ plan: host.syncPlan(), revision: snapshotRevision }));
  const push = plan.push ? await fetchReply("POST", "/mutations", plan.push) : null;
  const snapshot = plan.bootstrap ? (early?.status === 200 ? early : await fetchReply("GET", "/bootstrap")) : null;

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
    // After a bootstrap the next poll reads the cursor and the identity afresh.
    currentCursor = plan.bootstrap ? null : result.cursor;
    if (result.changed || result.notified) {
      save(result.notified ? result.changes : null);
    }

    if (result.pending > 0 || needsBootstrap) {
      kickSync(drainDelayMs);
      drainDelayMs = Math.min(drainDelayMs * 2, DRAIN_RETRY_CAP_MS);
    } else {
      drainDelayMs = DRAIN_RETRY_BASE_MS;
    }
    return result;
  });
  if (!initial && result.notified) {
    self.postMessage({ type: "records_changed", changes: result.changes, reads: activeReads });
  }
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
      currentIdentity = state.identity;
    }
    const who = currentIdentity ? `&identity=${encodeURIComponent(currentIdentity)}` : "";
    const { status, text } = await fetchReply("GET", `/events?after=${currentCursor}&window=0${who}`);
    if (status !== 200) return;
    if (!text.trim() || draining || kickTimer || revision !== snapshotRevision) return;

    const changed = await withSnapshot("readwrite", save => {
      if (draining || kickTimer || revision !== snapshotRevision) return;
      const consumed = host.consumeStream(text);
      currentCursor = consumed.cursor;
      // The server said this browser synced as someone else, and the client dropped what it
      // held. Bootstrap as whoever is here now, at once, and never poll from zero.
      if (!consumed.bootstrapped) {
        currentCursor = null;
        kickSync(0);
      }
      if (consumed.applied > 0 || consumed.notified) {
        save(consumed.changes);
        return { applied: consumed.applied, changes: consumed.changes };
      }
    });
    if (changed) {
      if (branches.isActive()) {
        const state = branches.noteMainDelta(changed.applied || 1);
        if (state) self.postMessage({ type: "instant_record.branch", state });
      } else {
        self.postMessage({ type: "records_changed", changes: changed.changes, reads: activeReads });
      }
    }
  } catch {
    // offline: try again on the next interval
  } finally {
    pollInFlight = false;
  }
}

// A page of older rows, or the rows matching `search`, brought into the local database.
// Where the background fill already holds them, nothing is asked of the server.
async function loadHistory(request) {
  // The fill's own copy of the state is not touched here: another tab may have finished it.
  if (mailScope) {
    const state = fillState?.done ? fillState : await withFiles("readonly", get => get(FILL));
    if (held(state)) return { ok: true, applied: 0, has_more: false };
  }
  const params = new URLSearchParams(request.search ? { search: request.search } : { type: request.type });
  if (request.before) {
    params.set("before_created_at", request.before.created_at);
    params.set("before_id", request.before.id);
    params.set("limit", String(request.limit));
  }
  if (request.partition != null) params.set("partition", request.partition);
  const key = params.toString();
  return loadHistoryQuery(key);
}

let mailScope = "";
let fillState = null;
let fillTimer = null;
let fillDelayMs = FILL_PAUSE_MS;

function scheduleFill(delay = fillDelayMs) {
  clearTimeout(fillTimer);
  fillTimer = setTimeout(runFill, delay);
}

// The page shows a count as a floor until the whole inbox is here.
function announceFill() {
  self.postMessage({ type: "instant_record.history", state: { done: fillState.done, full: fillState.full, rows: fillState.rows } });
}

// One page of the fill. Answers whether there is another to fetch.
async function fillStep() {
  fillState = (await withFiles("readonly", get => get(FILL))) || fresh();
  announceFill();
  if (fillState.done || fillState.full) return false;
  // A write waiting to be sent goes first, and offline/branched there is nothing to fetch.
  if (simulation.offline || draining || kickTimer || branches.isActive()) return true;

  const key = query(fillState, FILL_PAGE);
  const revision = snapshotRevision;
  const reply = await fetchReply("GET", "/records?" + key);
  if (reply.status !== 200) {
    fillDelayMs = Math.min(Math.max(fillDelayMs, 1000) * 2, FILL_RETRY_CAP_MS);
    return true;
  }
  const page = JSON.parse(reply.text);
  await withSnapshot("readwrite", (save, put) => {
    // Another tab saved meanwhile. Its database was just loaded here: read the state again.
    if (revision !== snapshotRevision) return;
    host.history(key, reply.text);
    fillState = advance(fillState, page, host.databaseBytes().length, FILL_BUDGET_BYTES);
    // The edge is saved with the rows it describes, or not at all.
    put(FILL, fillState);
    save();
  });
  fillDelayMs = FILL_PAUSE_MS;
  announceFill();
  const more = !(fillState.done || fillState.full);
  // Counts and "is there more" were answered for part of the inbox. Ask again for all of it.
  if (!more) self.postMessage({ type: "records_changed" });
  return more;
}

// One tab fills at a time. The others read what it saved.
async function runFill() {
  let more = true;
  try {
    const locks = self.navigator?.locks;
    more = locks
      ? await locks.request("instant-record-fill/" + mailScope, { ifAvailable: true }, lock => (lock ? fillStep() : true))
      : await fillStep();
  } catch {
    fillDelayMs = Math.min(Math.max(fillDelayMs, 1000) * 2, FILL_RETRY_CAP_MS);
  }
  if (more) scheduleFill(simulation.offline ? 2000 : fillDelayMs);
}

async function loadHistoryQuery(key) {
  // A save that lands during the fetch sends this round again. The background fill saves
  // often, so one collision is ordinary and a reader should not be told the page failed.
  let result;
  for (let attempt = 0; attempt < 4; attempt++) {
    const local = await withSnapshot("readonly", () => host.history(key));
    if (local.ok) return local;
    const revision = snapshotRevision;
    const reply = await fetchReply("GET", "/records?" + key);
    if (reply.status !== 200) return { ok: false, error: "History unavailable" };
    result = await withSnapshot("readwrite", save => {
      if (revision !== snapshotRevision) return { ok: false, busy: true };
      const applied = host.history(key, reply.text);
      save();
      return applied;
    });
    if (!result.busy) return result;
  }
  return result;
}

function runRequest(method, render) {
  const writing = method !== "GET" && method !== "HEAD";
  if (branches.isActive()) {
    const result = render(branches.host());
    if (writing) {
      self.postMessage({ type: "instant_record.branch", state: branches.inspect() });
    }
    return Promise.resolve(result);
  }
  return withSnapshot(writing ? "readwrite" : "readonly", save => {
    const result = render(host);
    if (writing) {
      localRevision++;
      const deltaChanges = result?.notified ? result.changes : null;
      save(deltaChanges);
      drainDelayMs = DRAIN_RETRY_BASE_MS;
      kickSync();
    }
    return result;
  });
}

function recordReads(method, path, result) {
  if (method !== "GET" || result.status < 200 || result.status >= 300 || !result.reads) return;
  const params = new URL(path, self.location.origin).searchParams;
  const partial = params.has("_only") || params.has("fragment");
  activeReads = partial ? mergeReads(activeReads, result.reads) : result.reads;
}

function localRequest(method, path, options, targetHost = host) {
  const started = performance.now();
  const result = targetHost.request(method, path, options);
  recordReads(method, path, result);
  report({ kind: "local", method, path, status: result.status, ms: Math.round(performance.now() - started) });
  return result;
}

function navigate({ method, path, body, contentType }, targetHost = host) {
  const started = performance.now();
  let result = localRequest(method, path, { body: body ?? "", contentType: contentType || "application/x-www-form-urlencoded" }, targetHost);
  const notified = result.notified;
  const writeChanges = result.changes;
  let redirected = false;
  let finalPath = path;
  for (let hops = 0; hops < 5 && result.status >= 300 && result.status < 400; hops++) {
    const location = result.headers.find(([name]) => name.toLowerCase() === "location")?.[1];
    if (!location) break;
    const next = new URL(location, self.location.origin);
    finalPath = next.pathname + next.search;
    redirected = true;
    result = localRequest("GET", finalPath, undefined, targetHost);
  }
  return { result: { ...result, ms: performance.now() - started }, redirected, finalPath, notified, changes: writeChanges };
}

// A browser with no database of its own asks for the inbox's shell. Anything short of a whole
// SQLite file built for this schema is no shell, and the normal bootstrap runs as before.
async function fetchShell(scope, path) {
  const asked = new URL(path || "/", self.location.origin).searchParams.get("shell") === "1";
  if (!scope || !shellFingerprint || !(shellAlways || asked) || simulation.offline) return null;
  const started = performance.now();
  try {
    if (await withFiles("readonly", get => get(DATABASE))) return null;
    const grant = await fetchReply("GET", "/shell?fingerprint=" + shellFingerprint);
    if (grant.status !== 200) return null;
    const { path: file, cursor } = JSON.parse(grant.text);
    const response = await fetch(syncEndpoint + file, { signal: AbortSignal.timeout(30000) });
    if (!response.ok) return null;
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (new TextDecoder().decode(bytes.subarray(0, 15)) !== "SQLite format 3") return null;
    return { bytes, cursor, ms: performance.now() - started };
  } catch {
    return null;
  }
}

// A browser with no database of its own will ask for a first sync as soon as the app is up.
// Nothing in the question depends on the app, so it is asked while the module compiles and the
// answer is waiting when the app wants it. A build that loads a shell has no use for it.
async function earlyBootstrap(path) {
  const asked = new URL(path || "/", self.location.origin).searchParams.get("shell") === "1";
  if (shellFingerprint && (shellAlways || asked)) return null;
  try {
    if ((await withFiles("readonly", get => get(SCHEMA))) != null) return null;
    return await fetchReply("GET", "/bootstrap");
  } catch {
    return null;
  }
}

async function boot(payload = {}) {
  const scope = mailboxScope(payload.path || "/");
  syncScope = typeof payload.scope === "string" ? payload.scope : "";
  openSnapshot(scope);
  changes = new BroadcastChannel("instant-record-spinel-changes" + (scope ? "/" + scope : ""));
  changes.onmessage = (event) => {
    if (!host) return;
    const { changes: peerChanges } = decodeBroadcast(event?.data);
    if (branches.isActive()) {
      const state = branches.noteMainDelta(peerChanges ? Math.max(peerChanges.length, 1) : 1);
      if (state) self.postMessage({ type: "instant_record.branch", state });
    } else {
      self.postMessage({ type: "records_changed", changes: peerChanges, reads: activeReads });
    }
  };
  if (scope) syncEndpoint = serverRoot(publicEndpoint, mountPath) + "/email/sync/" + scope;
  const started = performance.now();
  // The shell downloads while the module compiles.
  const shellFetch = fetchShell(scope, payload.path);
  const bootstrapFetch = earlyBootstrap(payload.path);
  const module = payload.module || await WebAssembly.compileStreaming(fetch(import.meta.env.VITE_WASM_URL || "/app.wasm"));
  const compiled = performance.now();
  let storageMs, runtimeMs;
  let shell = await shellFetch;
  const open = () => withFiles("readwrite", async (get, put) => {
    const opening = performance.now();
    const [bytes, version, revision, savedSecret, history, previousDigest] = await Promise.all([
      get(DATABASE), get(SCHEMA), get(REVISION), get("secret_key_base"), get("migration_history"), get("schema_digest"),
    ]);
    storageMs = performance.now() - opening;
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
    // Another tab may have saved a database while the shell downloaded. That one wins.
    const fromShell = !bytes && !!shell;
    if (bytes) candidate.restoreDatabase(bytes, previous);
    if (fromShell) candidate.restoreDatabase(shell.bytes, targetSchema);
    const initStart = performance.now();
    candidate.ensureBooted();
    runtimeMs = performance.now() - initStart;
    if (fromShell) {
      // The shell's cursor is its last write. One that did not arrive whole has none.
      const state = candidate.syncState();
      if (!state.bootstrapped || state.cursor !== shell.cursor) throw new Error("The shell does not carry its cursor.");
    } else {
      shell = null;
    }
    snapshotRevision = revision;
    if (fromShell || version !== targetSchema || !previousDigest) {
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
  let restored;
  try {
    restored = await open();
  } catch (error) {
    // A shell this build cannot open costs one attempt. The transaction rolled back, so the
    // second attempt starts from an empty database and bootstraps as it always has.
    if (!shell) throw error;
    report({ kind: "sync", method: "GET", path: "/shell", status: "rejected", ms: Math.round(shell.ms) });
    shell = null;
    restored = await open();
  }
  const bootstrapStart = performance.now();
  if (!restored && !shell) await drain(true, await bootstrapFetch);
  // The shell is as old as its cursor. Ask for what came after it now, not at the first
  // interval, and do not hold the first page for the answer.
  if (shell) pollChanges();
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
  // With the first page on screen, bring the rest of the inbox down behind it.
  if (scope && scope !== "invalid/invalid") {
    mailScope = scope;
    scheduleFill(1000);
  }
  return { compileMs: compiled - started, restored, storageMs, runtimeMs, bootstrapMs, first,
    shell: shell ? { ms: shell.ms, bytes: shell.bytes.length, cursor: shell.cursor } : null };
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
      const targetPath = resolveServerRequest(payload.path, self.location.origin);
      const root = serverRoot(publicEndpoint, mountPath);
      const method = (payload.method || "GET").toUpperCase();
      const body = typeof payload.body === "string" ? payload.body : "";
      const reply = await fetchReply(method, targetPath, body, root, payload.contentType ?? "");
      return self.postMessage({ id, result: reply });
    }
    if (type === "boot") return self.postMessage({ id, result: await boot(payload) });
    if (type === "navigate") return self.postMessage({ id, result: await runRequest(payload.method, target => navigate(payload, target)) });
    if (type === "request") {
      const started = performance.now();
      const result = await runRequest(payload.method, target => localRequest(payload.method, payload.path, { body: payload.body ?? "", contentType: payload.contentType || "application/x-www-form-urlencoded" }, target));
      return self.postMessage({ id, result: { ...result, ms: performance.now() - started } });
    }
    if (type === "save") return self.postMessage({ id, result: await withSnapshot("readwrite", save => save()) });
    if (type === "sync") return self.postMessage({ id, result: await syncPass() });
    if (type === "branch.create") {
      const state = await withSnapshot("readonly", () => branches.fork({
        name: payload?.name,
        mainHost: host,
        schemaVersion: targetSchema,
        createHost: (bytes, version, branchName) => {
          const staged = new AppHost(host.module, { env: { ...host.env, INSTANT_RECORD_BRANCH: branchName } });
          staged.cookies = new Map(host.cookies);
          staged.restoreDatabase(bytes, version);
          return staged;
        },
      }));
      report({ kind: "branch", method: "FORK", path: state.name, status: "staged" });
      self.postMessage({ type: "instant_record.branch", state });
      return self.postMessage({ id, result: state });
    }
    if (type === "branch.status") {
      return self.postMessage({ id, result: branches.inspect() });
    }
    if (type === "branch.approve") {
      const result = await branches.approve({
        conflict: payload?.conflict || "lww",
        onMain: (mutations, conflict) => withSnapshot("readwrite", save => {
          const replay = host.branchReplay(mutations, { conflict });
          if (replay.applied > 0) {
            localRevision++;
            save();
          }
          return replay;
        }),
      });
      if (result.applied > 0 || host.syncState().pending > 0) {
        drainDelayMs = DRAIN_RETRY_BASE_MS;
        kickSync(0);
      }
      report({ kind: "branch", method: "APPROVE", path: `${result.name} (${result.applied} applied, ${result.skipped} skipped)`, status: 200 });
      self.postMessage({ type: "instant_record.branch", state: { active: false, lastAction: result } });
      self.postMessage({ type: "records_changed", changes: result.changes || null });
      return self.postMessage({ id, result });
    }
    if (type === "branch.discard") {
      const result = branches.discard();
      if (host.syncState().pending > 0) {
        drainDelayMs = DRAIN_RETRY_BASE_MS;
        kickSync(0);
      }
      report({ kind: "branch", method: "DISCARD", path: `${result.name} (${result.dropped} dropped)`, status: 200 });
      self.postMessage({ type: "instant_record.branch", state: { active: false, lastAction: result } });
      self.postMessage({ type: "records_changed", changes: null });
      return self.postMessage({ id, result });
    }
  } catch (error) {
    self.postMessage({ id, error: String(error && error.message ? error.message : error) });
  }
};
