// Core worker runtime: coordinates leader election per (origin, scope), OPFS page-level
// WASI SQLite storage (with IndexedDB fallback), non-blocking outbox draining, change
// polling, background history fill, and multi-tab RPC routing.
import { BranchManager } from "./branch-manager.js";
import { advance, fresh, held, query } from "./history-fill.js";
import { mailboxScope } from "./mailbox-scope.js";
import { createLeaderCoordinator } from "./leader-election.js";
import { resolveServerRequest, serverRoot } from "./server-request.js";
import { openDatabaseStorage } from "./storage-backend.js";
import { nextSyncAction } from "./sync-schedule.js";

const POLL_EVERY_MS = 1000;
const QUIET_MS = 30;
const DRAIN_RETRY_BASE_MS = 500;
const DRAIN_RETRY_CAP_MS = 10000;

const DATABASE = "development.sqlite3";
const FILL = "history_fill";
const FILL_PAGE = 200;
const FILL_PAUSE_MS = 300;
const FILL_RETRY_CAP_MS = 60000;
const REVISION = "snapshot_revision";
const SCHEMA = "rails_schema_version";
const STORAGE_BACKEND = "storage_backend";

function randomHex(bytes) {
  const buf = new Uint8Array(bytes);
  globalThis.crypto.getRandomValues(buf);
  return [...buf].map(b => b.toString(16).padStart(2, "0")).join("");
}

export function createWorkerRuntime({
  env = {},
  AppHost,
  PagedSyncOPFSFile,
  openSnapshot,
  withFiles,
  openStorage = openDatabaseStorage,
  createCoordinator = createLeaderCoordinator,
  fetchImpl = (...args) => globalThis.fetch(...args),
  postMessage = msg => globalThis.postMessage(msg),
  origin = globalThis.location?.origin || "http://localhost",
  locks = globalThis.navigator?.locks,
  storageApi = globalThis.navigator?.storage,
  createChannel,
  compileWasm = url => WebAssembly.compileStreaming(fetchImpl(url)),
  pollIntervalMs = POLL_EVERY_MS,
  fillInitialDelayMs = 1000,
  scopeOf = path => mailboxScope(path, !!env.VITE_SHARED_INBOX_DEMO),
  now = () => performance.now(),
} = {}) {
  const publicEndpoint = env.VITE_SYNC_ENDPOINT || "/instant_record";
  const mountPath = env.VITE_MOUNT_PATH || "/instant_record";
  let syncEndpoint = publicEndpoint;
  const targetSchema = Number(env.VITE_SCHEMA_VERSION);
  const legacySchema = env.VITE_SCHEMA_BASELINE;
  const migrationHistory = JSON.parse(env.VITE_MIGRATION_HISTORY || "{}");
  const schemaDigest = env.VITE_SCHEMA_DIGEST || "";
  const shellFingerprint = env.VITE_SHELL_FINGERPRINT || "";
  const shellAlways = env.VITE_SHELL_SNAPSHOT === "1";
  const sourceVersion = env.VITE_SOURCE_VERSION || "";
  const wasmUrl = env.VITE_WASM_URL || "/app.wasm";

  let syncScope = "";
  let currentScope = "";
  let localSimulation = { offline: false, latencyMs: 0, report: false };
  const history = [];

  let coordinator = null;
  let storage = null;
  let host = null;
  const branches = new BranchManager();
  let snapshotRevision;
  let currentCursor = null;
  let currentIdentity = "";
  let kickTimer = null;
  let kickHeld = false;
  let pollTimer = null;
  let pollInFlight = false;
  let draining = null;
  let localRevision = 0;
  let drainDelayMs = DRAIN_RETRY_BASE_MS;

  let mailScope = "";
  let fillState = null;
  let fillTimer = null;
  let fillInFlight = false;
  let fillDelayMs = FILL_PAUSE_MS;

  let savedBootPayload = null;
  let savedModule = null;
  let dbQueue = Promise.resolve();
  let snapshotOpened = false;

  function isLeaderOrStandalone() {
    return coordinator && (coordinator.role === "leader" || coordinator.role === "standalone");
  }

  function effectiveSimulation() {
    if (coordinator && coordinator.role === "leader") return coordinator.effectiveSimulation();
    return localSimulation;
  }

  function report(entry) {
    const stamped = { ...entry, at: Date.now() };
    history.push(stamped);
    if (history.length > 150) history.shift();
    if (coordinator && coordinator.role === "leader") {
      if (localSimulation.report) postMessage({ type: "instant_record.debug", entry: stamped });
      coordinator.notifyOthers(coordinator.workerId, { type: "instant_record.debug", entry: stamped });
    } else if (localSimulation.report) {
      postMessage({ type: "instant_record.debug", entry: stamped });
    }
  }

  function emitRecordsChanged(changes = null, { excludeTabId = null } = {}) {
    if (coordinator && coordinator.role === "leader") {
      coordinator.broadcast({ type: "records_changed", changes }, { excludeTabId });
    } else if (excludeTabId == null) {
      postMessage({ type: "records_changed", changes });
    }
  }

  function emitBranchState(state) {
    if (!state) return;
    const msg = { type: "instant_record.branch", state };
    if (coordinator && coordinator.role === "leader") {
      coordinator.broadcast(msg);
    } else {
      postMessage(msg);
    }
  }

  function emitSyncNotices(notices) {
    const msg = { type: "instant_record.sync_notices", notices: Array.isArray(notices) ? notices : [] };
    if (coordinator && coordinator.role === "leader") {
      coordinator.broadcast(msg);
    } else {
      postMessage(msg);
    }
  }

  async function runNoticeAction(payload = { action: "list" }) {
    const action = payload.action || "list";
    if (action === "list") {
      return withDb("readonly", () => host.notices({ action: "list" }));
    }
    const result = await withDb("readwrite", save => {
      const resolved = host.notices(payload);
      if (resolved.ok) {
        localRevision++;
        save();
        if (action === "retry" || action === "fork") {
          drainDelayMs = DRAIN_RETRY_BASE_MS;
          kickSync();
        }
      }
      return resolved;
    });
    if (Array.isArray(result.notices)) emitSyncNotices(result.notices);
    if (result.notified) emitRecordsChanged(result.changes);
    return result;
  }

  function matchSyncNoticeRoute(method, path, body = "", contentType = "") {
    const url = new URL(path, origin);
    const base = new URL(publicEndpoint, origin).pathname.replace(/\/+$/, "") + "/sync_notices";
    const pathname = url.pathname.replace(/\.json$/, "");
    let verb = method.toUpperCase();
    if (verb === "POST" && (!contentType || contentType.startsWith("application/x-www-form-urlencoded"))) {
      const text = typeof body === "string" ? body : new TextDecoder().decode(body || new Uint8Array());
      const override = new URLSearchParams(text).get("_method");
      if (override && /^delete$/i.test(override)) verb = "DELETE";
    }
    if (pathname === base && verb === "GET") return { action: "list", json: url.pathname.endsWith(".json") };
    if (!pathname.startsWith(base + "/")) return null;
    const parts = pathname.slice(base.length + 1).split("/");
    const id = decodeURIComponent(parts[0] || "");
    if (!id) return null;
    if (parts.length === 1 && verb === "DELETE") return { action: "dismiss", id, json: url.pathname.endsWith(".json") };
    if (parts.length === 2 && verb === "POST" && ["retry", "fork", "dismiss"].includes(parts[1])) {
      return { action: parts[1], id, json: url.pathname.endsWith(".json") };
    }
    return null;
  }

  function parseNoticeForm(body, contentType) {
    const text = typeof body === "string" ? body : new TextDecoder().decode(body || new Uint8Array());
    if (contentType && contentType.includes("application/json")) {
      try {
        const parsed = JSON.parse(text || "{}");
        return { overrides: parsed.overrides || {}, returnTo: parsed.return_to || "" };
      } catch {
        return { overrides: {}, returnTo: "" };
      }
    }
    const params = new URLSearchParams(text);
    const overrides = {};
    for (const [key, value] of params.entries()) {
      const match = /^overrides\[(.+)\]$/.exec(key);
      if (match) overrides[match[1]] = value;
    }
    return { overrides, returnTo: params.get("return_to") || "" };
  }

  function handleSyncNoticeHttp(route, body, contentType, targetHost = host) {
    const { overrides, returnTo } = parseNoticeForm(body, contentType);
    const result = targetHost.notices(route.action === "list" ? { action: "list" } : { action: route.action, id: route.id, overrides });
    const status = result.ok ? (route.json || route.action === "list" ? 200 : 303) : 422;
    const headers = [];
    let responseBody = "";
    if (status === 303) {
      const target = returnTo && returnTo.startsWith("/") && !returnTo.startsWith("//") ? returnTo : "/";
      headers.push(["Location", target]);
    } else {
      headers.push(["Content-Type", "application/json; charset=utf-8"]);
      responseBody = JSON.stringify(result);
    }
    return { status, headers, body: responseBody, exit: 0, errors: [], noticeResult: result };
  }

  function announceFill() {
    if (!fillState) return;
    const msg = {
      type: "instant_record.history",
      state: { done: fillState.done, full: fillState.full, rows: fillState.rows },
    };
    if (coordinator && coordinator.role === "leader") {
      coordinator.broadcast(msg);
    } else {
      postMessage(msg);
    }
  }

  function ensureSnapshotOpen(scope) {
    if (snapshotOpened) return;
    snapshotOpened = true;
    openSnapshot(scope);
  }

  // Serialize DB operations on the leader without ever holding this lock across network I/O.
  function serializeDb(fn) {
    const run = dbQueue.then(fn, fn);
    dbQueue = run.then(() => {}, () => {});
    return run;
  }

  async function withDb(mode, operation) {
    return serializeDb(async () => {
      if (!host) throw new Error("AppHost is not booted");

      if (storage?.mode === "opfs") {
        let dirty = false;
        const metaUpdates = [];
        const save = () => {
          host.flushDatabase();
          snapshotRevision = (snapshotRevision ?? 0) + 1;
          dirty = true;
        };
        const putMeta = (key, value) => {
          metaUpdates.push([key, value]);
        };
        const result = await operation(save, putMeta);
        if (metaUpdates.length > 0) {
          await withFiles("readwrite", async (_get, put) => {
            for (const [key, value] of metaUpdates) put(key, value);
            if (dirty) put(REVISION, snapshotRevision);
          });
        }
        return result;
      }

      // IndexedDB fallback mode (whole-file snapshots).
      try {
        return await withFiles(mode, async (get, put) => {
          const revision = await get(REVISION);
          // Only standalone (no Web Locks) needs to check for peer writes in IndexedDB.
          if (coordinator?.role === "standalone" && revision !== snapshotRevision) {
            if ((await get(SCHEMA)) !== targetSchema) {
              postMessage({ type: "release_required" });
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
          }, put);
        });
      } catch (error) {
        if (coordinator?.role === "standalone") snapshotRevision = Symbol("reload");
        throw error;
      }
    });
  }

  async function fetchReply(method, path, body = "", endpoint = syncEndpoint, contentType = undefined) {
    const url = endpoint + path;
    const started = now();
    const poll = path.startsWith("/events?");
    let status = 0;
    let text = "";
    let responseContentType = "";
    let outcome = "failed";
    try {
      if (coordinator?.role === "leader") await coordinator.pruneDeadPeers();
      const sim = effectiveSimulation();
      if (sim.latencyMs && !sim.offline) {
        await new Promise(resolve => setTimeout(resolve, sim.latencyMs));
      }
      if (effectiveSimulation().offline) {
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
      const response = await fetchImpl(scoped, options);
      text = await response.text();
      responseContentType = response.headers?.get?.("content-type") || "";
      outcome = status = response.status;
    } catch {
      // A failed exchange stays in the durable outbox for retry.
    } finally {
      if (!poll || status !== 200 || text.trim()) {
        report({
          kind: poll ? "stream" : "sync",
          method,
          path: new URL(url, origin).pathname,
          status: outcome,
          ms: Math.round(now() - started),
        });
      }
    }
    return { method, url, body, status, text, contentType: responseContentType };
  }

  function kickSync(delay = QUIET_MS, { held = false } = {}) {
    if (!isLeaderOrStandalone() || branches.isActive()) return;
    clearTimeout(kickTimer);
    kickHeld = held;
    kickTimer = setTimeout(syncPass, delay);
  }

  function clearHeldKick() {
    if (kickTimer && kickHeld) {
      clearTimeout(kickTimer);
      kickTimer = null;
      kickHeld = false;
    }
  }

  function applySyncSchedule(action) {
    if (action.kind === "immediate") kickSync(action.delay);
    else if (action.kind === "held") kickSync(action.delay, { held: true });
    else clearHeldKick();
  }

  function handleOnline() {
    if (!isLeaderOrStandalone()) return;
    kickSync(0);
    if (mailScope && fillState && !fillState.done && !fillState.full) scheduleFill(0);
  }

  function syncPass() {
    if (!isLeaderOrStandalone()) return Promise.resolve({ changed: false });
    clearTimeout(kickTimer);
    kickTimer = null;
    kickHeld = false;
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

  async function drain(initial = false, early = null) {
    if (branches.isActive()) return { changed: false, skipped: true };
    const { plan, revision } = await withDb("readonly", () => ({ plan: host.syncPlan(), revision: localRevision }));
    if (!plan.push && !plan.bootstrap) {
      drainDelayMs = DRAIN_RETRY_BASE_MS;
      applySyncSchedule(nextSyncAction({ pending: 0, bootstrapped: true, nextReleaseMs: plan.next_release_ms ?? null }, QUIET_MS));
      return { changed: false, notified: false, pending: 0, nextReleaseMs: plan.next_release_ms ?? null };
    }
    const push = plan.push ? await fetchReply("POST", "/mutations", plan.push) : null;
    const snapshot = plan.bootstrap ? (early?.status === 200 ? early : await fetchReply("GET", "/bootstrap")) : null;

    const result = await withDb("readwrite", save => {
      if (revision !== localRevision) {
        kickSync();
        return { changed: false, retried: true };
      }
      const applied = host.sync(syncEndpoint, (method, url, body) => {
        const reply = method === "POST" ? push : snapshot;
        if (!reply || reply.method !== method || reply.url !== url || reply.body !== body) {
          throw new Error("Unexpected request while applying prepared sync responses");
        }
        return { status: reply.status, body: reply.text };
      });
      const needsBootstrap = plan.bootstrap && !host.syncState().bootstrapped;
      if (push || snapshot) report({ kind: "sync-pass", path: `${applied.pending} pending` });
      currentCursor = plan.bootstrap ? null : applied.cursor;
      const syncNotices = applied.notices?.length ? host.notices({ action: "list" }).notices : null;
      if (applied.changed || applied.notified) {
        localRevision++;
        save();
      }
      const action = nextSyncAction(
        { pending: applied.pending, bootstrapped: !needsBootstrap, nextReleaseMs: applied.nextReleaseMs },
        drainDelayMs,
      );
      if (action.kind === "immediate") {
        kickSync(action.delay);
        drainDelayMs = Math.min(drainDelayMs * 2, DRAIN_RETRY_CAP_MS);
      } else {
        drainDelayMs = DRAIN_RETRY_BASE_MS;
        applySyncSchedule(action);
      }
      return { ...applied, syncNotices };
    });
    if (result.syncNotices) emitSyncNotices(result.syncNotices);
    if (!initial && result.notified) emitRecordsChanged(result.changes);
    return result;
  }

  async function pollChanges() {
    if (!isLeaderOrStandalone() || !host || pollInFlight || draining || (kickTimer && !kickHeld)) return;
    const revision = localRevision;
    pollInFlight = true;
    try {
      if (currentCursor === null) {
        const state = await withDb("readonly", () => host.syncState());
        const action = nextSyncAction(state, 0);
        if (action.kind === "immediate") {
          kickSync(0);
          return;
        }
        applySyncSchedule(action);
        currentCursor = state.cursor;
        currentIdentity = state.identity;
      }
      const who = currentIdentity ? `&identity=${encodeURIComponent(currentIdentity)}` : "";
      const { status, text } = await fetchReply("GET", `/events?after=${currentCursor}&window=0${who}`);
      if (status !== 200) return;
      if (!text.trim() || draining || (kickTimer && !kickHeld) || revision !== localRevision) return;

      const changed = await withDb("readwrite", save => {
        if (draining || (kickTimer && !kickHeld) || revision !== localRevision) return;
        const consumed = host.consumeStream(text);
        currentCursor = consumed.cursor;
        if (!consumed.bootstrapped) {
          currentCursor = null;
          kickSync(0);
        }
        const syncNotices = consumed.notices?.length ? host.notices({ action: "list" }).notices : null;
        if (consumed.applied > 0 || consumed.notified) {
          localRevision++;
          save();
          return { applied: consumed.applied, changes: consumed.changes, syncNotices };
        }
      });
      if (changed?.syncNotices) emitSyncNotices(changed.syncNotices);
      if (changed) {
        if (branches.isActive()) {
          emitBranchState(branches.noteMainDelta(changed.applied || 1));
        } else {
          emitRecordsChanged(changed.changes);
        }
      }
    } catch {
      // offline: try again on the next interval
    } finally {
      pollInFlight = false;
    }
  }

  async function loadHistory(request) {
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
    return loadHistoryQuery(params.toString());
  }

  function scheduleFill(delay = fillDelayMs) {
    if (!isLeaderOrStandalone()) return;
    clearTimeout(fillTimer);
    fillTimer = setTimeout(runFill, delay);
  }

  async function fillStep() {
    fillState = (await withFiles("readonly", get => get(FILL))) || fresh();
    announceFill();
    if (fillState.done || fillState.full) return false;
    if (effectiveSimulation().offline || draining || (kickTimer && !kickHeld) || branches.isActive()) return true;

    const key = query(fillState, FILL_PAGE);
    const revision = localRevision;
    const reply = await fetchReply("GET", "/records?" + key);
    if (reply.status !== 200) {
      fillDelayMs = Math.min(Math.max(fillDelayMs, 1000) * 2, FILL_RETRY_CAP_MS);
      return true;
    }
    const page = JSON.parse(reply.text);
    const applied = await withDb("readwrite", (save, put) => {
      if (revision !== localRevision) return false;
      host.history(key, reply.text);
      const dbBytes = host.databaseSize();
      const budget = storage?.fillBudgetBytes ?? (24 * 1024 * 1024);
      fillState = advance(fillState, page, dbBytes, budget);
      localRevision++;
      put(FILL, fillState);
      save();
      return true;
    });
    if (!applied) return true;
    fillDelayMs = FILL_PAUSE_MS;
    announceFill();
    const more = !(fillState.done || fillState.full);
    if (!more) emitRecordsChanged(null);
    return more;
  }

  async function runFill() {
    if (!isLeaderOrStandalone() || fillInFlight) return;
    fillInFlight = true;
    let more = true;
    try {
      more = await fillStep();
    } catch {
      fillDelayMs = Math.min(Math.max(fillDelayMs, 1000) * 2, FILL_RETRY_CAP_MS);
    } finally {
      fillInFlight = false;
    }
    if (more && isLeaderOrStandalone()) {
      scheduleFill(effectiveSimulation().offline ? 2000 : fillDelayMs);
    }
  }

  async function loadHistoryQuery(key) {
    let result;
    for (let attempt = 0; attempt < 4; attempt++) {
      const local = await withDb("readonly", () => host.history(key));
      if (local.ok) return local;
      const revision = localRevision;
      const reply = await fetchReply("GET", "/records?" + key);
      if (reply.status !== 200) return { ok: false, error: "History unavailable" };
      result = await withDb("readwrite", save => {
        if (revision !== localRevision) return { ok: false, busy: true };
        const applied = host.history(key, reply.text);
        localRevision++;
        save();
        return applied;
      });
      if (!result.busy) return result;
    }
    return result;
  }

  async function runRequest(method, render, { tabId = null } = {}) {
    const writing = method !== "GET" && method !== "HEAD";
    if (branches.isActive()) {
      const result = render(branches.host());
      if (writing) emitBranchState(branches.inspect());
      return result;
    }
    const result = await withDb(writing ? "readwrite" : "readonly", save => {
      const rendered = render(host);
      if (writing) {
        localRevision++;
        save();
        drainDelayMs = DRAIN_RETRY_BASE_MS;
        applySyncSchedule(nextSyncAction(host.syncState(), QUIET_MS));
      }
      return rendered;
    });
    if (writing) {
      // Peer tabs need to refresh when another tab mutates local SQLite.
      emitRecordsChanged(null, { excludeTabId: tabId });
    }
    return result;
  }

  function localRequest(method, path, options, targetHost = host) {
    const started = now();
    const noticeRoute = matchSyncNoticeRoute(method, path, options?.body, options?.contentType);
    const result = noticeRoute
      ? handleSyncNoticeHttp(noticeRoute, options?.body, options?.contentType, targetHost)
      : targetHost.request(method, path, options);
    if (result.noticeResult && Array.isArray(result.noticeResult.notices)) {
      emitSyncNotices(result.noticeResult.notices);
    }
    report({ kind: "local", method, path, status: result.status, ms: Math.round(now() - started) });
    return result;
  }

  function navigate({ method, path, body, contentType }, targetHost = host) {
    const started = now();
    let result = localRequest(method, path, { body: body ?? "", contentType: contentType || "application/x-www-form-urlencoded" }, targetHost);
    let redirected = false;
    let finalPath = path;
    for (let hops = 0; hops < 5 && result.status >= 300 && result.status < 400; hops++) {
      const location = result.headers.find(([name]) => name.toLowerCase() === "location")?.[1];
      if (!location) break;
      const next = new URL(location, origin);
      finalPath = next.pathname + next.search;
      redirected = true;
      result = localRequest("GET", finalPath, undefined, targetHost);
    }
    return { result: { ...result, ms: now() - started }, redirected, finalPath };
  }

  async function fetchShell(scope, path, hasExistingDb) {
    const asked = new URL(path || "/", origin).searchParams.get("shell") === "1";
    if (!scope || !shellFingerprint || !(shellAlways || asked) || effectiveSimulation().offline || hasExistingDb) return null;
    const started = now();
    try {
      const grant = await fetchReply("GET", "/shell?fingerprint=" + shellFingerprint);
      if (grant.status !== 200) return null;
      const { path: file, cursor } = JSON.parse(grant.text);
      const response = await fetchImpl(syncEndpoint + file, { signal: AbortSignal.timeout(30000) });
      if (!response.ok) return null;
      const bytes = new Uint8Array(await response.arrayBuffer());
      if (new TextDecoder().decode(bytes.subarray(0, 15)) !== "SQLite format 3") return null;
      return { bytes, cursor, ms: now() - started };
    } catch {
      return null;
    }
  }

  async function earlyBootstrap(path, hasExistingMeta) {
    const asked = new URL(path || "/", origin).searchParams.get("shell") === "1";
    if (hasExistingMeta || (shellFingerprint && (shellAlways || asked))) return null;
    try {
      return await fetchReply("GET", "/bootstrap");
    } catch {
      return null;
    }
  }

  function validateSchemaMetadata({ hasExistingDb, version, savedHistory, previousDigest }) {
    if (hasExistingDb && version == null && !legacySchema) {
      throw new Error("Set compiled_migration_baseline to the schema version of the previously deployed browser app.");
    }
    const previous = version ?? Number(legacySchema);
    if (hasExistingDb && (previous > targetSchema || (legacySchema && previous < Number(legacySchema)))) {
      throw new Error("This release cannot migrate the saved schema version " + previous + ".");
    }
    if (savedHistory) {
      const priorVersions = new Set([...Object.keys(savedHistory), ...Object.keys(migrationHistory)]);
      for (const key of priorVersions) {
        if (Number(key) <= previous && migrationHistory[key] !== savedHistory[key]) {
          throw new Error("Published migration " + key + " changed. Add a new migration instead.");
        }
      }
    }
    if (version === targetSchema && previousDigest && previousDigest !== schemaDigest) {
      throw new Error("The compiled schema changed without a new Rails migration version.");
    }
    if (hasExistingDb && previous < targetSchema && !(targetSchema in migrationHistory)) {
      throw new Error("Missing browser migration for schema version " + targetSchema + ".");
    }
    return previous;
  }

  async function openLeaderDatabase(module, { scope, path, promoted }) {
    ensureSnapshotOpen(scope);
    const storageStart = now();
    storage = await openStorage(scope, {
      storage: storageApi,
      createFile: handle => new PagedSyncOPFSFile(handle),
    });

    const meta = await withFiles("readonly", async get => {
      const [legacyBytes, version, revision, savedSecret, savedHistory, previousDigest, savedBackend] = await Promise.all([
        get(DATABASE), get(SCHEMA), get(REVISION), get("secret_key_base"),
        get("migration_history"), get("schema_digest"), get(STORAGE_BACKEND),
      ]);
      return { legacyBytes, version, revision, savedSecret, savedHistory, previousDigest, savedBackend };
    });
    const storageMs = now() - storageStart;

    const orphanOpfs = storage.mode === "opfs" && storage.hasDatabase() &&
      meta.version == null && meta.revision == null && meta.savedBackend == null;
    if (orphanOpfs) storage.truncate(0);

    const hasExistingDb = storage.mode === "opfs"
      ? (storage.hasDatabase() || !!meta.legacyBytes)
      : !!meta.legacyBytes;

    // On failover promotion, the DB already exists — never fetch a fresh shell or bootstrap.
    const shellFetch = promoted ? Promise.resolve(null) : fetchShell(scope, path, hasExistingDb);
    const bootstrapFetch = promoted ? Promise.resolve(null) : earlyBootstrap(path, hasExistingDb || meta.version != null);

    let shell = await shellFetch;
    let runtimeMs = 0;

    const openOnce = async () => {
      if (storage.mode === "opfs") {
        let opfsHasBytes = storage.hasDatabase();
        let migratedFromIdb = false;
        let version = meta.version;
        let previousDigest = meta.previousDigest;
        let savedHistory = meta.savedHistory;

        if (!opfsHasBytes && meta.legacyBytes) {
          storage.writeAllBytes(meta.legacyBytes);
          opfsHasBytes = true;
          migratedFromIdb = true;
        } else if (!opfsHasBytes && !meta.legacyBytes && meta.savedBackend === "opfs") {
          // OPFS was cleared externally while IDB metadata remained; start cleanly.
          version = null;
          previousDigest = null;
          savedHistory = null;
        }

        const existing = opfsHasBytes;
        const previous = validateSchemaMetadata({
          hasExistingDb: existing,
          version,
          savedHistory,
          previousDigest,
        });
        const secret = meta.savedSecret || randomHex(64);
        const fromShell = !existing && !!shell;

        const candidate = new AppHost(module, { env: { SECRET_KEY_BASE: secret } });
        // Back up bytes ONLY when a schema migration is about to mutate an existing OPFS DB.
        const migrationBackup = existing && previous < targetSchema ? storage.readAllBytes() : null;
        if (fromShell) storage.writeAllBytes(shell.bytes);

        candidate.mountDatabase(storage.file, fromShell ? targetSchema : (existing ? previous : targetSchema));
        const initStart = now();
        try {
          candidate.ensureBooted();
          runtimeMs = now() - initStart;
          if (fromShell) {
            const state = candidate.syncState();
            if (!state.bootstrapped || state.cursor !== shell.cursor) {
              throw new Error("The shell does not carry its cursor.");
            }
          } else {
            shell = null;
          }
        } catch (error) {
          if (migrationBackup) {
            storage.writeAllBytes(migrationBackup);
          } else if (fromShell || !existing) {
            storage.truncate(0);
          }
          throw error;
        }

        candidate.flushDatabase();
        const needsMetaWrite = !meta.savedSecret || fromShell || version !== targetSchema ||
          !previousDigest || migratedFromIdb || meta.savedBackend !== "opfs";

        snapshotRevision = meta.revision ?? 0;
        if (needsMetaWrite) {
          snapshotRevision = (meta.revision ?? 0) + 1;
          await withFiles("readwrite", async (_get, put, del) => {
            if (!meta.savedSecret) put("secret_key_base", secret);
            put(REVISION, snapshotRevision);
            put(SCHEMA, targetSchema);
            put("migration_history", migrationHistory);
            put("schema_digest", schemaDigest);
            put(STORAGE_BACKEND, "opfs");
            // Reclaim legacy whole-file IDB snapshot once OPFS boot succeeds.
            if (migratedFromIdb || meta.legacyBytes) del(DATABASE);
          });
        }
        host = candidate;
        return existing;
      }

      // IndexedDB fallback path (whole-file transaction).
      return withFiles("readwrite", async (get, put) => {
        const [bytes, version, revision, savedSecret, savedHistory, previousDigest] = await Promise.all([
          get(DATABASE), get(SCHEMA), get(REVISION), get("secret_key_base"),
          get("migration_history"), get("schema_digest"),
        ]);
        const previous = validateSchemaMetadata({
          hasExistingDb: !!bytes,
          version,
          savedHistory,
          previousDigest,
        });
        const secret = savedSecret || randomHex(64);
        if (!savedSecret) put("secret_key_base", secret);
        const candidate = new AppHost(module, { env: { SECRET_KEY_BASE: secret } });
        const fromShell = !bytes && !!shell;
        if (bytes) candidate.restoreDatabase(bytes, previous);
        if (fromShell) candidate.restoreDatabase(shell.bytes, targetSchema);
        const initStart = now();
        candidate.ensureBooted();
        runtimeMs = now() - initStart;
        if (fromShell) {
          const state = candidate.syncState();
          if (!state.bootstrapped || state.cursor !== shell.cursor) {
            throw new Error("The shell does not carry its cursor.");
          }
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
          put(STORAGE_BACKEND, "indexeddb");
        }
        host = candidate;
        return !!bytes;
      });
    };

    let restored;
    try {
      try {
        restored = await openOnce();
      } catch (error) {
        if (!shell) throw error;
        report({ kind: "sync", method: "GET", path: "/shell", status: "rejected", ms: Math.round(shell.ms) });
        shell = null;
        restored = await openOnce();
      }
    } catch (error) {
      // Release the OPFS sync handle if boot or schema validation fails.
      storage?.close();
      storage = null;
      throw error;
    }

    const bootstrapStart = now();
    if (!restored && !shell) await drain(true, await bootstrapFetch);
    if (restored) applySyncSchedule(nextSyncAction(host.syncState(), 0));
    if (shell) pollChanges();
    const bootstrapMs = now() - bootstrapStart;

    clearInterval(pollTimer);
    if (pollIntervalMs > 0) pollTimer = setInterval(pollChanges, pollIntervalMs);

    if (scope && scope !== "invalid/invalid") {
      mailScope = scope;
      scheduleFill(fillInitialDelayMs);
    }

    return {
      restored,
      storageMs,
      runtimeMs,
      bootstrapMs,
      storageMode: storage.mode,
      shell: shell ? { ms: shell.ms, bytes: shell.bytes.length, cursor: shell.cursor } : null,
    };
  }

  async function preloadPathHistory(scope, path) {
    if (!scope || !path) return;
    const url = new URL(path, origin);
    for (const id of new Set([url.searchParams.get("before"), url.searchParams.get("thread")])) {
      if (id) await loadHistoryQuery(new URLSearchParams({ thread: id }).toString());
    }
    const before = url.searchParams.get("before");
    const at = url.searchParams.get("at");
    if (before && at) {
      await loadHistory({ type: "MailEntry", before: { id: before, created_at: at }, limit: 50 });
    }
  }

  async function handleServerRequest(payload) {
    const targetPath = resolveServerRequest(payload.path, origin);
    const root = serverRoot(publicEndpoint, mountPath);
    const method = (payload.method || "GET").toUpperCase();
    const body = typeof payload.body === "string" ? payload.body : "";
    return fetchReply(method, targetPath, body, root, payload.contentType ?? "");
  }

  async function wipeLocalStorage() {
    clearInterval(pollTimer);
    clearTimeout(kickTimer);
    clearTimeout(fillTimer);
    pollTimer = null;
    kickTimer = null;
    kickHeld = false;
    fillTimer = null;
    host = null;
    if (storage) {
      await storage.wipe();
      storage = null;
    }
    coordinator?.close({ announceBye: true });
    return { ok: true };
  }

  async function handleLeaderRpc(method, payload, { tabId }) {
    if (method === "boot_tab") {
      if (payload?.syncScope && !syncScope) syncScope = payload.syncScope;
      await preloadPathHistory(currentScope, payload?.path);
      const first = payload?.path
        ? await runRequest("GET", target => navigate({ method: "GET", path: payload.path }, target), { tabId })
        : null;
      return {
        first,
        storageMode: storage?.mode || "indexeddb",
        fillState: fillState ? { done: fillState.done, full: fillState.full, rows: fillState.rows } : null,
      };
    }
    if (method === "navigate") {
      return runRequest(payload.method, target => navigate(payload, target), { tabId });
    }
    if (method === "request") {
      const started = now();
      const result = await runRequest(
        payload.method,
        target => localRequest(payload.method, payload.path, {
          body: payload.body ?? "",
          contentType: payload.contentType || "application/x-www-form-urlencoded",
        }, target),
        { tabId },
      );
      return { ...result, ms: now() - started };
    }
    if (method === "branch.create") {
      const state = await withDb("readonly", () => branches.fork({
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
      emitBranchState(state);
      return state;
    }
    if (method === "branch.status") {
      return branches.inspect();
    }
    if (method === "branch.approve") {
      const result = await branches.approve({
        conflict: payload?.conflict || "lww",
        onMain: (mutations, conflict) => withDb("readwrite", save => {
          const replay = host.branchReplay(mutations, { conflict });
          if (replay.applied > 0) {
            localRevision++;
            save();
          }
          return replay;
        }),
      });
      const postApproveState = host.syncState();
      if (result.applied > 0 || postApproveState.pending > 0 || postApproveState.nextReleaseMs != null) {
        drainDelayMs = DRAIN_RETRY_BASE_MS;
        applySyncSchedule(nextSyncAction(result.applied > 0 ? { ...postApproveState, pending: Math.max(postApproveState.pending, 1) } : postApproveState, 0));
      }
      report({ kind: "branch", method: "APPROVE", path: `${result.name} (${result.applied} applied, ${result.skipped} skipped)`, status: 200 });
      emitBranchState({ active: false, lastAction: result });
      emitRecordsChanged(result.changes || null);
      return result;
    }
    if (method === "branch.discard") {
      const result = branches.discard();
      const postDiscardState = host.syncState();
      if (postDiscardState.pending > 0 || postDiscardState.nextReleaseMs != null) {
        drainDelayMs = DRAIN_RETRY_BASE_MS;
        applySyncSchedule(nextSyncAction(postDiscardState, 0));
      }
      report({ kind: "branch", method: "DISCARD", path: `${result.name} (${result.dropped} dropped)`, status: 200 });
      emitBranchState({ active: false, lastAction: result });
      emitRecordsChanged(null);
      return result;
    }
    if (method === "fetch_history") {
      return loadHistory(payload);
    }
    if (method === "save") {
      return withDb("readwrite", save => save());
    }
    if (method === "sync") {
      return syncPass();
    }
    if (method === "notices") {
      return runNoticeAction(payload || { action: "list" });
    }
    if (method === "serverRequest") {
      return handleServerRequest(payload);
    }
    if (method === "wipe") {
      return wipeLocalStorage();
    }
    throw new Error("Unknown leader RPC method: " + method);
  }

  async function boot(payload = {}) {
    savedBootPayload = payload;
    currentScope = scopeOf(payload.path || "/");
    syncScope = typeof payload.scope === "string" ? payload.scope : "";
    if (currentScope) {
      syncEndpoint = serverRoot(publicEndpoint, mountPath) + "/email/sync/" + currentScope;
    }

    const started = now();
    savedModule = payload.module || await compileWasm(wasmUrl);
    const compiled = now();

    coordinator = createCoordinator({
      scope: currentScope,
      sourceVersion,
      targetSchema,
      locks,
      ...(createChannel ? { createChannel } : {}),
      onBecomeLeader: async ({ promoted }) => {
        return openLeaderDatabase(savedModule, {
          scope: currentScope,
          path: savedBootPayload?.path || "/",
          promoted,
        });
      },
      onRpc: handleLeaderRpc,
      onLeaderMessage: (msg, { reply }) => {
        if (msg.type === "clear_log") {
          history.length = 0;
        } else if (msg.type === "simulate" && msg.backlog) {
          reply?.({ type: "instant_record.debug_backlog", entries: history, streamOpen: false });
        }
      },
      onLeaderSimulationChange: (next, prev) => {
        if (host && prev.offline && !next.offline) {
          drainDelayMs = DRAIN_RETRY_BASE_MS;
          kickSync(0);
          if (mailScope && fillState && !fillState.done && !fillState.full) scheduleFill(0);
        }
      },
      onFollowerPush: msg => {
        if (msg) postMessage(msg);
      },
      onRoleChange: nextRole => {
        postMessage({ type: "instant_record.role", role: nextRole });
      },
    });

    // Apply any simulation settings that arrived before boot.
    coordinator.updateSimulation(localSimulation);

    const startedRole = await coordinator.start();

    if (startedRole.role === "leader" || startedRole.role === "standalone") {
      const bootInfo = startedRole.bootResult;
      await preloadPathHistory(currentScope, payload.path);
      const first = payload.path
        ? await runRequest("GET", target => navigate({ method: "GET", path: payload.path }, target), { tabId: coordinator.workerId })
        : null;
      if (host && typeof host.notices === "function" && host.syncState().notices > 0) {
        emitSyncNotices(host.notices({ action: "list" }).notices);
      }
      return {
        compileMs: compiled - started,
        restored: bootInfo.restored,
        storageMs: bootInfo.storageMs,
        runtimeMs: bootInfo.runtimeMs,
        bootstrapMs: bootInfo.bootstrapMs,
        first,
        shell: bootInfo.shell,
        role: startedRole.role,
        storageMode: bootInfo.storageMode,
      };
    }

    // Follower path: leader already owns the hot AppHost and storage.
    const tabBoot = await coordinator.call("boot_tab", { path: payload.path, syncScope }, { idempotent: true });
    if (tabBoot.fillState) {
      postMessage({ type: "instant_record.history", state: tabBoot.fillState });
    }
    return {
      compileMs: compiled - started,
      restored: true,
      storageMs: 0,
      runtimeMs: 0,
      bootstrapMs: 0,
      first: tabBoot.first,
      shell: null,
      role: "follower",
      storageMode: tabBoot.storageMode,
    };
  }

  function shutdown({ announceBye = true } = {}) {
    clearInterval(pollTimer);
    clearTimeout(kickTimer);
    clearTimeout(fillTimer);
    pollTimer = null;
    kickTimer = null;
    kickHeld = false;
    fillTimer = null;
    if (storage) {
      storage.close();
      storage = null;
    }
    host = null;
    coordinator?.close({ announceBye });
  }

  async function handleMessage(event) {
    const { id, type, payload } = event.data;
    try {
      if (type === "instant_record.bye") {
        shutdown({ announceBye: true });
        return;
      }
      if (type === "instant_record.clear_log") {
        history.length = 0;
        coordinator?.clearLog();
        return;
      }
      if (type === "instant_record.simulate") {
        const previous = localSimulation;
        localSimulation = {
          offline: !!event.data.settings?.offline,
          latencyMs: Number(event.data.settings?.latencyMs) || 0,
          report: !!event.data.settings?.report,
        };
        if (coordinator) {
          coordinator.updateSimulation(localSimulation, { backlog: !!event.data.backlog });
        } else if (event.data.backlog) {
          postMessage({ type: "instant_record.debug_backlog", entries: history, streamOpen: false });
        }
        if (isLeaderOrStandalone() && host && previous.offline && !localSimulation.offline && !effectiveSimulation().offline) {
          drainDelayMs = DRAIN_RETRY_BASE_MS;
          kickSync(0);
        }
        return;
      }
      if (type === "instant_record.fetch_history") {
        const port = event.ports[0];
        try {
          if (!coordinator) throw new Error("Worker not booted");
          const reply = await coordinator.call("fetch_history", event.data.request, { idempotent: true });
          port.postMessage(reply);
        } catch (error) {
          port.postMessage({ ok: false, error: error.message });
        }
        return;
      }
      if (type === "serverRequest") {
        const idempotent = payload.method === "GET" || payload.method === "HEAD";
        const reply = coordinator
          ? await coordinator.call("serverRequest", payload, { idempotent })
          : await handleServerRequest(payload);
        return postMessage({ id, result: reply });
      }
      if (type === "boot") return postMessage({ id, result: await boot(payload) });
      if (type === "navigate") {
        const idempotent = payload.method === "GET" || payload.method === "HEAD";
        return postMessage({ id, result: await coordinator.call("navigate", payload, { idempotent }) });
      }
      if (type === "request") {
        const idempotent = payload.method === "GET" || payload.method === "HEAD";
        return postMessage({ id, result: await coordinator.call("request", payload, { idempotent }) });
      }
      if (type === "save") return postMessage({ id, result: await coordinator.call("save", null, { idempotent: true }) });
      if (type === "sync") return postMessage({ id, result: await coordinator.call("sync", null, { idempotent: true }) });
      if (type === "notices") {
        const action = payload?.action || "list";
        return postMessage({ id, result: await coordinator.call("notices", payload || { action: "list" }, { idempotent: action === "list" }) });
      }
      if (type === "wipe") return postMessage({ id, result: await coordinator.call("wipe", null, { idempotent: true }) });
      if (type === "branch.create") return postMessage({ id, result: await coordinator.call("branch.create", payload, { idempotent: false }) });
      if (type === "branch.status") return postMessage({ id, result: await coordinator.call("branch.status", payload, { idempotent: true }) });
      if (type === "branch.approve") return postMessage({ id, result: await coordinator.call("branch.approve", payload, { idempotent: false }) });
      if (type === "branch.discard") return postMessage({ id, result: await coordinator.call("branch.discard", payload, { idempotent: false }) });
    } catch (error) {
      postMessage({ id, error: String(error && error.message ? error.message : error) });
    }
  }

  return {
    boot,
    handleMessage,
    handleOnline,
    shutdown,
    fillStep,
    syncPass,
    pollChanges,
    get role() { return coordinator?.role || "idle"; },
    get storageMode() { return storage?.mode || coordinator?.storageMode || null; },
    get fillState() { return fillState; },
  };
}
