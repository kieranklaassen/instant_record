// Core worker runtime: coordinates leader election per (origin, partition), OPFS page-level
// WASI SQLite storage (with IndexedDB fallback), non-blocking outbox draining, a
// leader-elected visibility-aware SSE change stream, server-directed background history fill,
// and multi-tab RPC routing.
import { BranchManager } from "./branch-manager.js";
import { CircuitBreaker, WasmFaultError } from "./faults.js";
import { FlightRecorder } from "./flight-recorder.js";
import { advance, fresh, held, query } from "./history-fill.js";
import { redirectHeaders } from "./http-headers.js";
import { createLeaderCoordinator } from "./leader-election.js";
import { isServerAllowed, parseManifest } from "./manifest.js";
import { detectSchemaDrift, openOrRehydrate, rehydrateFromBytes, reloadOrRehydrateSnapshot } from "./schema-recovery.js";
import { resolveServerRequest, serverRoot } from "./server-request.js";
import { isValidSqliteBytes, parseShellGrant, shouldFetchShell, validateShellState } from "./shell.js";
import { openDatabaseStorage } from "./storage-backend.js";
import { createStreamLeader } from "./stream-leader.js";
import { parseRules, resolveSyncContext } from "./sync-context.js";
import { runDrain } from "./sync-drain.js";
import { nextSyncAction } from "./sync-schedule.js";

const QUIET_MS = 30;
const DRAIN_RETRY_BASE_MS = 500;
const DRAIN_RETRY_CAP_MS = 10000;

const DATABASE = "development.sqlite3";
const FILL = "history_fill";
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

function parseTraceSchema(raw) {
  try {
    return JSON.parse(raw || "{}");
  } catch {
    return {};
  }
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
  pollIntervalMs = 1000,
  streamEnabled = pollIntervalMs !== 0,
  streamOptions = {},
  fillInitialDelayMs = 1000,
  contextOf = path => resolveSyncContext(path, parseRules(env.VITE_SYNC_PARTITIONS)),
  now = () => performance.now(),
} = {}) {
  const manifest = parseManifest(env.VITE_MANIFEST);
  const syncEndpoint = env.VITE_SYNC_ENDPOINT || "/instant_record";
  const mountPath = env.VITE_MOUNT_PATH || "/instant_record";
  const targetSchema = Number(env.VITE_SCHEMA_VERSION);
  const legacySchema = env.VITE_SCHEMA_BASELINE;
  const migrationHistory = JSON.parse(env.VITE_MIGRATION_HISTORY || "{}");
  const schemaDigest = env.VITE_SCHEMA_DIGEST || "";
  const shellFingerprint = env.VITE_SHELL_FINGERPRINT || "";
  const shellAlways = env.VITE_SHELL_SNAPSHOT === "1";
  const sourceVersion = env.VITE_SOURCE_VERSION || "";
  const wasmUrl = env.VITE_WASM_URL || "/app.wasm";

  // Client-side sync scope & pluggable headers (partition, auth, custom headers).
  let syncScope = "";
  let syncHeaders = {};
  let syncContext = null;
  let currentScope = "";
  let localSimulation = { offline: false, latencyMs: 0, report: false };
  const history = [];

  let coordinator = null;
  let storage = null;
  let host = null;
  const branches = new BranchManager();
  let snapshotRevision;
  let kickTimer = null;
  let kickHeld = false;
  let draining = null;
  let localRevision = 0;
  const drainRetry = { baseMs: DRAIN_RETRY_BASE_MS, capMs: DRAIN_RETRY_CAP_MS, delayMs: DRAIN_RETRY_BASE_MS };

  let streamLeader = null;
  let streamOpen = false;
  let pageVisible = true;
  let pageTornDown = false;
  let pageSuspended = false;
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
    emitToTabs(msg);
  }

  function emitToTabs(msg) {
    if (coordinator && coordinator.role === "leader") {
      coordinator.broadcast(msg);
    } else {
      postMessage(msg);
    }
  }

  function stopBackgroundTimers() {
    clearTimeout(kickTimer);
    kickTimer = null;
    kickHeld = false;
    clearTimeout(fillTimer);
    fillTimer = null;
    streamLeader?.setCanLead?.(false);
  }

  const breaker = new CircuitBreaker({
    maxConsecutiveFailures: 3,
    onTrip: snapshot => {
      stopBackgroundTimers();
      console.error(`[instant_record] Circuit breaker OPEN (${snapshot.tripReason})`, snapshot);
    },
  });

  const recorder = new FlightRecorder({
    enabled: false,
    schema: parseTraceSchema(env.VITE_TRACE_SCHEMA),
  });

  function traceMeta() {
    return {
      sourceVersion,
      schemaVersion: targetSchema || 0,
      schemaDigest,
      wasmUrl,
      syncEndpoint,
      userAgent: globalThis.navigator?.userAgent || "",
    };
  }

  function handleHostFault(fault) {
    const { trippedNow, snapshot } = breaker.recordFault(fault);
    console.error(
      `[instant_record] WASM fault in ${fault.exportName} (exit=${fault.exit}, circuit=${snapshot.state}): ${fault.message}`,
      fault.errors,
    );
    report({
      kind: "fault",
      path: `${fault.exportName}: ${fault.message}`,
      status: "failed",
      exit: fault.exit,
      errors: fault.errors,
      circuit: snapshot.state,
    });
    emitToTabs({
      type: "instant_record.fault",
      fault,
      circuit: snapshot,
      trippedNow,
      traceAvailable: recorder.enabled,
    });
  }

  function handleHostEvents(events, exportName) {
    for (const event of events) {
      const durationMs = typeof event.duration_ms === "number" ? Math.round(event.duration_ms) : undefined;
      report({
        kind: "ruby",
        path: event.name || "instant_record",
        status: event.payload?.exception ? "failed" : "ok",
        ms: durationMs,
        payload: event.payload || {},
        exportName,
      });
      emitToTabs({
        type: "instant_record.notification",
        name: event.name,
        payload: event.payload || {},
        durationMs: event.duration_ms ?? null,
        exportName,
        at: Date.now(),
      });
    }
  }

  function makeHost(mod, hostEnv = {}) {
    return new AppHost(mod, {
      env: hostEnv,
      onFault: handleHostFault,
      onEvents: handleHostEvents,
      onSuccess: exportName => breaker.recordSuccess(exportName),
      recorder,
    });
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
          drainRetry.delayMs = DRAIN_RETRY_BASE_MS;
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
    const base = new URL(syncEndpoint, origin).pathname.replace(/\/+$/, "") + "/sync_notices";
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
      breaker.assertClosed("withDb");
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
      let pendingPersist = null;
      let needsSync = false;
      try {
        const result = await withFiles(mode, async (get, put) => {
          const revision = await get(REVISION);
          let allowSave = true;
          // Only standalone (no Web Locks) needs to check for peer writes in IndexedDB.
          if (coordinator?.role === "standalone" && revision !== snapshotRevision) {
            const [bytes, savedSchema] = await Promise.all([get(DATABASE), get(SCHEMA)]);
            const previous = host;
            const recovered = reloadOrRehydrateSnapshot({
              bytes,
              savedSchema,
              targetSchema,
              createHost: () => {
                const next = makeHost(previous.module, previous.env);
                next.cookies = previous.cookies;
                return next;
              },
              onReleaseRequired: () => postMessage({ type: "release_required" }),
              onReport: report,
            });
            host = recovered.host;
            if (recovered.rehydrated) breaker.reset();
            localRevision++;
            if (recovered.rehydrated) {
              needsSync = true;
              if (recovered.persist) {
                const rebuiltBytes = host.databaseBytes();
                if (mode === "readwrite") {
                  snapshotRevision = (revision ?? 0) + 1;
                  put(DATABASE, rebuiltBytes);
                  put(REVISION, snapshotRevision);
                  put(SCHEMA, targetSchema);
                  put("migration_history", migrationHistory);
                  put("schema_digest", schemaDigest);
                  put(STORAGE_BACKEND, "indexeddb");
                  put(FILL, null);
                } else {
                  pendingPersist = { expectedRevision: revision, bytes: rebuiltBytes };
                }
              } else {
                allowSave = false;
                snapshotRevision = revision;
              }
            } else {
              snapshotRevision = revision;
            }
          }
          return operation(() => {
            if (!allowSave) return;
            const bytes = host.databaseBytes();
            if (!bytes) throw new Error("SQLite did not produce a database snapshot");
            snapshotRevision = (revision ?? 0) + 1;
            put(DATABASE, bytes);
            put(REVISION, snapshotRevision);
          }, put);
        });
        if (pendingPersist) {
          await withFiles("readwrite", async (get, put) => {
            const currentRev = await get(REVISION);
            const currentSchema = await get(SCHEMA);
            if (currentRev !== pendingPersist.expectedRevision || (currentSchema != null && currentSchema > targetSchema)) {
              return;
            }
            snapshotRevision = (currentRev ?? 0) + 1;
            put(DATABASE, pendingPersist.bytes);
            put(REVISION, snapshotRevision);
            put(SCHEMA, targetSchema);
            put("migration_history", migrationHistory);
            put("schema_digest", schemaDigest);
            put(STORAGE_BACKEND, "indexeddb");
            put(FILL, null);
          });
        }
        if (needsSync) kickSync(0);
        return result;
      } catch (error) {
        if (coordinator?.role === "standalone") snapshotRevision = Symbol("reload");
        throw error;
      }
    });
  }

  function buildHeaders(method, extra = {}, contentType = undefined) {
    const headers = { ...syncHeaders, ...extra };
    if (syncScope && !headers["X-Instant-Record-Scope"]) {
      headers["X-Instant-Record-Scope"] = syncScope;
    }
    if (method !== "GET" && method !== "HEAD") {
      const headerType = contentType === undefined ? "application/json" : contentType;
      if (headerType && !headers["Content-Type"]) headers["Content-Type"] = headerType;
    }
    return headers;
  }

  async function fetchReply(method, path, body = "", endpoint = syncEndpoint, extraHeaders = {}, contentType = undefined) {
    const url = endpoint + path;
    const started = now();
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
      const headers = buildHeaders(method, extraHeaders, contentType);
      const options = { method, signal: AbortSignal.timeout(30000) };
      if (Object.keys(headers).length > 0) options.headers = headers;
      if (method !== "GET" && method !== "HEAD") options.body = body;
      const response = await fetchImpl(url, options);
      text = await response.text();
      responseContentType = response.headers?.get?.("content-type") || "";
      outcome = status = response.status;
    } catch {
      // A failed exchange stays in the durable outbox for retry.
    } finally {
      report({
        kind: "sync",
        method,
        path: new URL(url, origin).pathname,
        status: outcome,
        ms: Math.round(now() - started),
      });
    }
    return { method, url, body, status, text, contentType: responseContentType };
  }

  function kickSync(delay = QUIET_MS, { held = false } = {}) {
    if (!isLeaderOrStandalone() || breaker.isOpen() || branches.isActive()) return;
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
    if (breaker.isOpen()) return;
    if (action.kind === "immediate") kickSync(action.delay);
    else if (action.kind === "held") kickSync(action.delay, { held: true });
    else clearHeldKick();
  }

  function handleOnline() {
    if (!breaker.isOpen()) streamLeader?.setOnline(true);
    if (!isLeaderOrStandalone() || breaker.isOpen()) return;
    kickSync(0);
    if (fillState && fillState.type && !fillState.done && !fillState.full) scheduleFill(0);
  }

  function handleOffline() {
    streamLeader?.setOnline(false);
  }

  function syncPass() {
    if (!isLeaderOrStandalone()) return Promise.resolve({ changed: false });
    clearTimeout(kickTimer);
    kickTimer = null;
    kickHeld = false;
    if (breaker.isOpen()) {
      return Promise.resolve({ changed: false, fault: breaker.lastFault, circuit: breaker.snapshot() });
    }
    if (branches.isActive()) return Promise.resolve({ skipped: true, reason: "branched" });
    if (!draining) {
      const revision = localRevision;
      let drainOutcome = null;
      draining = drain()
        .then(result => {
          drainOutcome = result;
          return result;
        })
        .catch(error => {
          if (error instanceof WasmFaultError || breaker.isOpen()) {
            drainOutcome = { changed: false, fault: error.fault || breaker.lastFault, circuit: breaker.snapshot() };
            return drainOutcome;
          }
          throw error;
        })
        .finally(() => {
          draining = null;
          if (!breaker.isOpen() && revision !== localRevision && !kickTimer) kickSync();
          if (!breaker.isOpen() && drainOutcome && !drainOutcome.skipped && !drainOutcome.fault) {
            if (drainOutcome.bootstrappedNow) streamLeader?.reconnect();
            else if (drainOutcome.pending === 0) streamLeader?.wake();
          }
        });
    }
    return draining;
  }

  async function drain(initial = false, early = null) {
    if (breaker.isOpen()) return { changed: false, fault: breaker.lastFault, circuit: breaker.snapshot() };
    if (branches.isActive()) return { changed: false, skipped: true };
    let hadBootstrap = false;
    const result = await runDrain({
      withSnapshot: (mode, op) => withDb(mode, (save, put) => op(() => {
        localRevision++;
        save();
      }, put)),
      fetchReply,
      getHost: () => host,
      syncEndpoint,
      initial,
      early,
      report,
      setCursor: cursor => { if (cursor === null) hadBootstrap = true; },
      onBootstrapFill: (descriptor, put) => {
        fillState = fresh(descriptor);
        put?.(FILL, fillState);
      },
      onRecordsChanged: changedRecords => emitRecordsChanged(changedRecords),
      onSyncNotices: notices => emitSyncNotices(notices),
      scheduleRetry: delay => { if (!breaker.isOpen()) kickSync(delay); },
      scheduleHeld: delay => { if (!breaker.isOpen()) applySyncSchedule({ kind: "held", delay }); },
      onIdle: () => applySyncSchedule({ kind: "idle" }),
      retryState: drainRetry,
    });
    const bootstrappedNow = hadBootstrap && !breaker.isOpen() && !result.fault && !!host?.syncState?.().bootstrapped;
    return { ...result, bootstrappedNow };
  }

  async function readStreamParams() {
    if (!isLeaderOrStandalone() || !host || breaker.isOpen() || draining || (kickTimer && !kickHeld)) return { ready: false };
    const state = await withDb("readonly", () => host.syncState());
    if (state.fault || (state.exit !== undefined && state.exit !== 0)) return { ready: false };
    const action = nextSyncAction(state, 0);
    if (action.kind === "immediate") {
      if (!draining && (!kickTimer || kickHeld)) kickSync(0);
      return { ready: false };
    }
    applySyncSchedule(action);
    return { ready: true, cursor: state.cursor, identity: state.identity };
  }

  async function applyStreamFrames(framesText) {
    if (draining) await draining.catch(() => {});
    if (!isLeaderOrStandalone() || !host || breaker.isOpen()) return { applied: 0, cursor: 0, reset: false };
    const outcome = await withDb("readwrite", save => {
      const previousState = host.syncState();
      if (previousState.fault || (previousState.exit !== undefined && previousState.exit !== 0)) {
        return { applied: 0, cursor: 0, reset: false, changes: null, notify: false, syncNotices: null, fault: previousState.fault };
      }
      const previousCursor = previousState.cursor;
      const consumed = host.consumeStream(framesText);
      if (consumed.fault || (consumed.exit !== undefined && consumed.exit !== 0)) {
        if (coordinator?.role === "standalone") snapshotRevision = Symbol("reload");
        return { applied: 0, cursor: previousCursor, reset: false, changes: null, notify: false, syncNotices: null, fault: consumed.fault };
      }
      const reset = !consumed.bootstrapped;
      const notify = consumed.applied > 0 || consumed.notified || reset;
      const syncNotices = consumed.notices?.length && typeof host.notices === "function"
        ? host.notices({ action: "list" }).notices
        : null;
      if (notify || consumed.cursor > previousCursor) {
        localRevision++;
        save();
      }
      return { applied: consumed.applied, cursor: consumed.cursor, reset, changes: notify ? consumed.changes : null, notify, syncNotices };
    });
    if (outcome.fault) return outcome;
    if (outcome.syncNotices) emitSyncNotices(outcome.syncNotices);
    if (outcome.reset && !breaker.isOpen()) kickSync(0);
    if (outcome.notify) {
      if (branches.isActive()) {
        emitBranchState(branches.noteMainDelta(outcome.applied || 1));
      } else {
        emitRecordsChanged(outcome.changes);
      }
    }
    return outcome;
  }

  function ensureStreamLeader() {
    if (!streamEnabled || streamLeader) return;
    streamLeader = createStreamLeader({
      ...streamOptions,
      getEndpoint: () => syncEndpoint,
      mailboxScope: currentScope,
      getSyncScope: () => syncScope,
      getHeaders: () => buildHeaders("GET"),
      initialVisible: pageVisible,
      canLead: false,
      locks,
      ...(createChannel ? { createChannel } : {}),
      fetch: fetchImpl,
      isOfflineSimulated: () => effectiveSimulation().offline,
      getLatencyMs: () => effectiveSimulation().latencyMs,
      getStreamParams: readStreamParams,
      applyFrames: applyStreamFrames,
      onReport: entry => report(entry),
      onStreamStateChange: open => {
        streamOpen = open;
        const msg = { type: "instant_record.stream_state", streamOpen: open };
        if (coordinator && coordinator.role === "leader") {
          coordinator.broadcast(msg);
        } else {
          postMessage(msg);
        }
      },
    });
    if (!pageTornDown) {
      streamLeader.start();
      if (pageSuspended) streamLeader.suspend();
    }
  }

  async function loadHistory(request) {
    breaker.assertClosed("loadHistory");
    const state = fillState?.done ? fillState : await withFiles("readonly", get => get(FILL));
    if (held(state) && (!state.type || !request.type || state.type === request.type)) {
      return { ok: true, applied: 0, has_more: false };
    }
    const params = new URLSearchParams();
    if (request.type) params.set("type", request.type);
    if (request.search) params.set("search", request.search);
    if (request.before) {
      params.set("before_created_at", request.before.created_at);
      params.set("before_id", request.before.id);
      params.set("limit", String(request.limit));
    }
    if (request.partition != null) params.set("partition", request.partition);
    return loadHistoryQuery(params.toString());
  }

  function scheduleFill(delay = fillDelayMs) {
    if (!isLeaderOrStandalone() || breaker.isOpen()) return;
    clearTimeout(fillTimer);
    fillTimer = setTimeout(runFill, delay);
  }

  async function fillStep() {
    if (breaker.isOpen()) return false;
    fillState = await withFiles("readonly", get => get(FILL));
    if (!fillState || !fillState.type) return false;
    announceFill();
    if (fillState.done || fillState.full) return false;
    if (effectiveSimulation().offline || draining || (kickTimer && !kickHeld) || branches.isActive()) return true;

    const key = query(fillState, fillState.pageSize);
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
    if (!isLeaderOrStandalone() || fillInFlight || breaker.isOpen()) return;
    fillInFlight = true;
    let more = true;
    try {
      more = await fillStep();
    } catch (error) {
      if (breaker.isOpen() || error instanceof WasmFaultError) {
        more = !breaker.isOpen();
      } else {
        fillDelayMs = Math.min(Math.max(fillDelayMs, 1000) * 2, FILL_RETRY_CAP_MS);
      }
    } finally {
      fillInFlight = false;
    }
    if (more && isLeaderOrStandalone() && !breaker.isOpen()) {
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
      const fault = result?.fault ?? result?.result?.fault ?? null;
      if (writing && !fault) emitBranchState(branches.inspect());
      return result;
    }
    const result = await withDb(writing ? "readwrite" : "readonly", save => {
      const rendered = render(host);
      const fault = rendered?.fault ?? rendered?.result?.fault ?? null;
      if (fault) {
        if (coordinator?.role === "standalone") snapshotRevision = Symbol("reload");
      } else if (writing) {
        localRevision++;
        save();
        drainRetry.delayMs = DRAIN_RETRY_BASE_MS;
        applySyncSchedule(nextSyncAction(host.syncState(), QUIET_MS));
      }
      return rendered;
    });
    const fault = result?.fault ?? result?.result?.fault ?? null;
    if (writing && !fault) {
      // Peer tabs receive typed row deltas when the write recorded them,
      // degrading cleanly to null (wildcard) when unlisted.
      const deltaChanges = result?.notified ? result.changes : null;
      emitRecordsChanged(deltaChanges, { excludeTabId: tabId });
    }
    return result;
  }

  function localRequest(method, path, options, targetHost = host) {
    breaker.assertClosed("request");
    const started = now();
    const noticeRoute = matchSyncNoticeRoute(method, path, options?.body, options?.contentType);
    const result = noticeRoute
      ? handleSyncNoticeHttp(noticeRoute, options?.body, options?.contentType, targetHost)
      : targetHost.request(method, path, options);
    if (result.noticeResult && Array.isArray(result.noticeResult.notices)) {
      emitSyncNotices(result.noticeResult.notices);
    }
    report({ kind: "local", method, path, status: result.fault ? "failed" : result.status, ms: Math.round(now() - started) });
    return result;
  }

  function navigate({ method, path, body, contentType, headers }, targetHost = host) {
    const started = now();
    let result = localRequest(
      method,
      path,
      { body: body ?? "", contentType: contentType || "application/x-www-form-urlencoded", headers },
      targetHost,
    );
    const notified = result.notified;
    const writeChanges = result.changes;
    let redirected = false;
    let finalPath = path;
    const followHeaders = redirectHeaders(headers);
    for (let hops = 0; hops < 5 && !result.fault && result.status >= 300 && result.status < 400; hops++) {
      const location = result.headers.find(([name]) => name.toLowerCase() === "location")?.[1];
      if (!location) break;
      const next = new URL(location, origin);
      finalPath = next.pathname + next.search;
      redirected = true;
      result = localRequest("GET", finalPath, { headers: followHeaders }, targetHost);
    }
    return { result: { ...result, ms: now() - started }, redirected, finalPath, notified, changes: writeChanges };
  }

  async function fetchShell(context, path, hasExistingDb) {
    if (hasExistingDb || !shouldFetchShell({
      path,
      fingerprint: shellFingerprint,
      always: shellAlways,
      offline: effectiveSimulation().offline,
      blocked: context ? !context.valid : false,
    })) {
      return null;
    }
    const started = now();
    try {
      const root = context?.shellPath ? serverRoot(syncEndpoint, mountPath) : syncEndpoint;
      const grantPath = `${context?.shellPath || "/shell"}?fingerprint=${encodeURIComponent(shellFingerprint)}`;
      const grant = await fetchReply("GET", grantPath, "", root);
      if (grant.status !== 200) return null;
      const parsed = parseShellGrant(grant.text);
      if (!parsed) return null;
      const response = await fetchImpl(root + parsed.path, {
        headers: buildHeaders("GET"),
        signal: AbortSignal.timeout(30000),
        cache: "no-store",
      });
      if (!response.ok) return null;
      const bytes = new Uint8Array(await response.arrayBuffer());
      if (!isValidSqliteBytes(bytes)) return null;
      return { bytes, cursor: parsed.cursor, identity: parsed.identity, fill: parsed.fill, ms: now() - started };
    } catch {
      return null;
    }
  }

  async function earlyBootstrap(context, path, hasExistingMeta) {
    if (hasExistingMeta || shouldFetchShell({
      path,
      fingerprint: shellFingerprint,
      always: shellAlways,
      offline: effectiveSimulation().offline,
      blocked: context ? !context.valid : false,
    })) {
      return null;
    }
    try {
      return await fetchReply("GET", "/bootstrap");
    } catch {
      return null;
    }
  }

  async function openLeaderDatabase(module, { context, scope, path, promoted }) {
    ensureSnapshotOpen(scope);
    const storageStart = now();
    storage = await openStorage(scope, {
      storage: storageApi,
      createFile: handle => new PagedSyncOPFSFile(handle),
    });

    const meta = await withFiles("readonly", async get => {
      const [legacyBytes, version, revision, savedSecret, savedHistory, previousDigest, savedBackend, savedFill] = await Promise.all([
        get(DATABASE), get(SCHEMA), get(REVISION), get("secret_key_base"),
        get("migration_history"), get("schema_digest"), get(STORAGE_BACKEND), get(FILL),
      ]);
      return { legacyBytes, version, revision, savedSecret, savedHistory, previousDigest, savedBackend, savedFill };
    });
    const storageMs = now() - storageStart;

    const orphanOpfs = storage.mode === "opfs" && storage.hasDatabase() &&
      meta.version == null && meta.revision == null && meta.savedBackend == null;
    if (orphanOpfs) storage.truncate(0);

    const hasExistingDb = storage.mode === "opfs"
      ? (storage.hasDatabase() || !!meta.legacyBytes)
      : !!meta.legacyBytes;

    // On failover promotion, the DB already exists — never fetch a fresh shell or bootstrap.
    const shellFetch = promoted ? Promise.resolve(null) : fetchShell(context, path, hasExistingDb);
    const bootstrapFetch = promoted ? Promise.resolve(null) : earlyBootstrap(context, path, hasExistingDb || meta.version != null);

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
        const secret = meta.savedSecret || randomHex(64);
        const createHost = () => makeHost(module, { SECRET_KEY_BASE: secret });
        const drift = detectSchemaDrift({
          bytes: existing ? new Uint8Array([1]) : null,
          version,
          targetSchema,
          legacySchema,
          history: savedHistory,
          migrationHistory,
          previousDigest,
          schemaDigest,
        });

        let candidate;
        let restoredOpfs = existing;
        let rehydrated = null;
        let fromShell = !existing && !!shell;

        const rehydrateOpfs = (oldBytes, reason) => {
          shell = null;
          fromShell = false;
          const outcome = rehydrateFromBytes({
            bytes: oldBytes,
            reason,
            createHost,
            prepareFresh: freshHost => {
              storage.truncate(0);
              freshHost.mountDatabase(storage.file, targetSchema);
            },
            onReport: report,
          });
          candidate = outcome.host;
          runtimeMs = outcome.runtimeMs;
          restoredOpfs = false;
          rehydrated = outcome.rehydrated;
        };

        if (drift) {
          rehydrateOpfs(existing ? storage.readAllBytes() : null, drift);
        } else {
          const previous = version ?? Number(legacySchema);
          candidate = createHost();
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
              if (!validateShellState(state, shell)) {
                throw new Error("The shell does not match its grant.");
              }
              if (shell.fill) fillState = fresh(shell.fill);
            } else {
              shell = null;
              if (meta.savedFill) fillState = meta.savedFill;
            }
          } catch (error) {
            if (existing) {
              try {
                rehydrateOpfs(migrationBackup || storage.readAllBytes(), "migration_failed");
              } catch (rehydrateError) {
                if (migrationBackup) storage.writeAllBytes(migrationBackup);
                throw rehydrateError;
              }
            } else {
              if (fromShell || !existing) storage.truncate(0);
              throw error;
            }
          }
        }

        candidate.flushDatabase();
        const needsMetaWrite = !meta.savedSecret || fromShell || !!rehydrated || version !== targetSchema ||
          !previousDigest || migratedFromIdb || meta.savedBackend !== "opfs";

        snapshotRevision = meta.revision ?? 0;
        if (needsMetaWrite) {
          snapshotRevision = (meta.revision ?? 0) + 1;
          await withFiles("readwrite", async (_get, put, del) => {
            if (!meta.savedSecret) put("secret_key_base", secret);
            if (fromShell && shell.fill) put(FILL, fillState);
            put(REVISION, snapshotRevision);
            put(SCHEMA, targetSchema);
            put("migration_history", migrationHistory);
            put("schema_digest", schemaDigest);
            put(STORAGE_BACKEND, "opfs");
            if (rehydrated) put(FILL, null);
            // Reclaim legacy whole-file IDB snapshot once OPFS boot succeeds.
            if (migratedFromIdb || meta.legacyBytes) del(DATABASE);
          });
        }
        host = candidate;
        return { restored: restoredOpfs, rehydrated };
      }

      // IndexedDB fallback path (whole-file transaction).
      return withFiles("readwrite", async (get, put) => {
        const [bytes, version, revision, savedSecret, savedHistory, previousDigest, savedFill] = await Promise.all([
          get(DATABASE), get(SCHEMA), get(REVISION), get("secret_key_base"),
          get("migration_history"), get("schema_digest"), get(FILL),
        ]);
        const secret = savedSecret || randomHex(64);
        if (!savedSecret) put("secret_key_base", secret);
        const outcome = openOrRehydrate({
          bytes,
          version,
          targetSchema,
          legacySchema,
          history: savedHistory,
          migrationHistory,
          previousDigest,
          schemaDigest,
          shell,
          createHost: () => makeHost(module, { SECRET_KEY_BASE: secret }),
          onReport: report,
        });
        const candidate = outcome.host;
        runtimeMs = outcome.runtimeMs;
        if (outcome.fromShell) {
          const state = candidate.syncState();
          if (!validateShellState(state, shell)) {
            throw new Error("The shell does not match its grant.");
          }
          if (shell.fill) {
            fillState = fresh(shell.fill);
            put(FILL, fillState);
          }
        } else {
          shell = null;
          if (savedFill) fillState = savedFill;
        }
        snapshotRevision = revision;
        if (outcome.fromShell || outcome.rehydrated || version !== targetSchema || !previousDigest) {
          snapshotRevision = (revision ?? 0) + 1;
          put(DATABASE, candidate.databaseBytes());
          put(REVISION, snapshotRevision);
          put(SCHEMA, targetSchema);
          put("migration_history", migrationHistory);
          put("schema_digest", schemaDigest);
          put(STORAGE_BACKEND, "indexeddb");
          if (outcome.rehydrated) put(FILL, null);
        }
        host = candidate;
        return { restored: outcome.restored, rehydrated: outcome.rehydrated };
      });
    };

    let opened;
    try {
      try {
        opened = await openOnce();
      } catch (error) {
        if (!shell) throw error;
        report({ kind: "sync", method: "GET", path: "/shell", status: "rejected", ms: Math.round(shell.ms) });
        shell = null;
        breaker.reset();
        opened = await openOnce();
      }
    } catch (error) {
      // Release the OPFS sync handle if boot or schema validation fails.
      storage?.close();
      storage = null;
      throw error;
    }

    const { restored, rehydrated } = opened;
    if (rehydrated) breaker.reset();
    if (recorder.enabled && !restored && !shell && host && typeof host.snapshotForRecorder === "function") {
      recorder.captureCheckpoint(host.snapshotForRecorder());
    }
    const bootstrapStart = now();
    if (!restored && !shell && !breaker.isOpen()) await drain(true, rehydrated ? null : await bootstrapFetch);
    if (restored && !breaker.isOpen()) {
      const state = host.syncState();
      if (!state.fault && (state.exit === undefined || state.exit === 0)) {
        applySyncSchedule(nextSyncAction(state, 0));
      }
    }
    ensureStreamLeader();
    if (!breaker.isOpen()) streamLeader?.setCanLead(true);
    const bootstrapMs = now() - bootstrapStart;

    if (!breaker.isOpen() && fillState && fillState.type && !fillState.done && !fillState.full) {
      scheduleFill(fillInitialDelayMs);
    } else if (fillState) {
      announceFill();
    }

    return {
      restored,
      rehydrated,
      storageMs,
      runtimeMs,
      bootstrapMs,
      storageMode: storage.mode,
      shell: shell ? { ms: shell.ms, bytes: shell.bytes.length, cursor: shell.cursor } : null,
    };
  }

  async function preloadPathHistory(context) {
    if (!context?.valid) return;
    for (const id of context.lookupIds) {
      await loadHistoryQuery(new URLSearchParams({ id }).toString());
    }
    if (context.preloadBefore) {
      await loadHistory(context.preloadBefore);
    }
  }

  async function handleServerRequest(payload) {
    const targetPath = resolveServerRequest(payload.path, origin);
    const method = (payload.method || "GET").toUpperCase();
    const pathname = new URL(targetPath, origin).pathname;
    if (manifest.mode === "island" && !isServerAllowed(manifest, method, pathname, syncEndpoint)) {
      throw new Error(`Disallowed server action: ${method} ${pathname}`);
    }
    const root = serverRoot(syncEndpoint, mountPath);
    const body = typeof payload.body === "string" ? payload.body : "";
    const reply = await fetchReply(method, targetPath, body, root, {}, payload.contentType ?? "");
    if (method !== "GET" && method !== "HEAD" && reply.status >= 200 && reply.status < 400) {
      streamLeader?.reconnect();
    }
    return reply;
  }

  async function wipeLocalStorage() {
    streamLeader?.stop();
    streamLeader = null;
    clearTimeout(kickTimer);
    clearTimeout(fillTimer);
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
      if (payload?.syncHeaders && typeof payload.syncHeaders === "object") {
        syncHeaders = { ...syncHeaders, ...payload.syncHeaders };
      }
      if (payload?.trace && !recorder.enabled) {
        recorder.configure({
          enabled: true,
          ...(typeof payload.trace === "object" ? payload.trace : {}),
          meta: traceMeta(),
        });
        if (host && typeof host.snapshotForRecorder === "function") {
          recorder.captureCheckpoint(host.snapshotForRecorder());
        }
      }
      const tabContext = payload?.path ? contextOf(payload.path) : syncContext;
      if (!breaker.isOpen()) await preloadPathHistory(tabContext);
      const first = payload?.path && !breaker.isOpen()
        ? await runRequest("GET", target => navigate({ method: "GET", path: payload.path, headers: payload.headers }, target), { tabId })
        : null;
      return {
        first,
        storageMode: storage?.mode || "indexeddb",
        fillState: fillState ? { done: fillState.done, full: fillState.full, rows: fillState.rows } : null,
        circuit: breaker.snapshot(),
      };
    }
    if (method === "configure_headers") {
      if (payload && typeof payload === "object") {
        syncHeaders = { ...syncHeaders, ...payload };
      }
      return { ok: true };
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
          headers: payload.headers,
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
          const staged = makeHost(host.module, { ...host.env, INSTANT_RECORD_BRANCH: branchName });
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
        drainRetry.delayMs = DRAIN_RETRY_BASE_MS;
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
        drainRetry.delayMs = DRAIN_RETRY_BASE_MS;
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
    if (method === "reset_circuit") {
      breaker.reset();
      if (coordinator?.role === "standalone") snapshotRevision = Symbol("reload");
      drainRetry.delayMs = DRAIN_RETRY_BASE_MS;
      if (host?.poisoned) {
        const previous = host;
        if (storage?.mode === "opfs" && storage.file) {
          const fresh = makeHost(previous.module, previous.env);
          fresh.cookies = previous.cookies;
          fresh.mountDatabase(storage.file, targetSchema);
          fresh.ensureBooted();
          host = fresh;
        } else {
          const bytes = await withFiles("readonly", get => get(DATABASE));
          const fresh = makeHost(previous.module, previous.env);
          fresh.cookies = previous.cookies;
          if (bytes) fresh.restoreDatabase(bytes, targetSchema);
          fresh.ensureBooted();
          host = fresh;
        }
      }
      if (isLeaderOrStandalone()) {
        streamLeader?.setCanLead?.(true);
        streamLeader?.wake?.();
      }
      const result = { ok: true, circuit: breaker.snapshot() };
      emitToTabs({ type: "instant_record.circuit", circuit: result.circuit });
      return result;
    }
    if (method === "trace.configure") {
      const options = payload || {};
      const wasEnabled = recorder.enabled;
      const status = recorder.configure({ ...options, meta: traceMeta() });
      if (!wasEnabled && recorder.enabled && host && typeof host.snapshotForRecorder === "function") {
        recorder.captureCheckpoint(host.snapshotForRecorder());
      }
      return status;
    }
    if (method === "trace.status") {
      return recorder.status();
    }
    if (method === "trace.clear") {
      recorder.clear();
      if (recorder.enabled && host && typeof host.snapshotForRecorder === "function") {
        recorder.captureCheckpoint(host.snapshotForRecorder());
      }
      return recorder.status();
    }
    if (method === "trace.export") {
      const options = payload || {};
      return recorder.exportTrace({
        redact: options.redact !== false,
        includeUnredactedDatabase: !!options.includeUnredactedDatabase,
        meta: traceMeta(),
        circuit: breaker.snapshot(),
      });
    }
    throw new Error("Unknown leader RPC method: " + method);
  }

  async function boot(payload = {}) {
    savedBootPayload = payload;
    syncContext = contextOf(payload.path || "/");
    currentScope = syncContext ? syncContext.storageKey : "";
    syncScope = typeof payload.scope === "string" ? payload.scope : "";
    syncHeaders = {
      ...(syncContext?.headers || {}),
      ...(payload.syncHeaders && typeof payload.syncHeaders === "object" ? payload.syncHeaders : {}),
    };
    if (typeof payload.visible === "boolean") pageVisible = payload.visible;
    if (payload.trace) {
      recorder.configure({
        enabled: true,
        ...(typeof payload.trace === "object" ? payload.trace : {}),
        meta: traceMeta(),
      });
    }

    const started = now();
    savedModule = payload.module || await compileWasm(wasmUrl);
    const compiled = now();

    ensureStreamLeader();

    coordinator = createCoordinator({
      scope: currentScope,
      sourceVersion,
      targetSchema,
      locks,
      ...(createChannel ? { createChannel } : {}),
      onBecomeLeader: async ({ promoted }) => {
        return openLeaderDatabase(savedModule, {
          context: syncContext,
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
          reply?.({ type: "instant_record.debug_backlog", entries: history, streamOpen });
        }
      },
      onLeaderSimulationChange: (next, prev) => {
        streamLeader?.setOfflineSimulated(!!next.offline);
        if (host && prev.offline && !next.offline && !breaker.isOpen()) {
          drainRetry.delayMs = DRAIN_RETRY_BASE_MS;
          kickSync(0);
          if (fillState && fillState.type && !fillState.done && !fillState.full) scheduleFill(0);
        }
      },
      onFollowerPush: msg => {
        if (msg) postMessage(msg);
      },
      onRoleChange: nextRole => {
        postMessage({ type: "instant_record.role", role: nextRole });
        if ((nextRole === "leader" || nextRole === "standalone") && !breaker.isOpen()) streamLeader?.wake();
      },
    });

    // Apply any simulation settings that arrived before boot.
    coordinator.updateSimulation(localSimulation);

    const startedRole = await coordinator.start();

    if (startedRole.role === "leader" || startedRole.role === "standalone") {
      const bootInfo = startedRole.bootResult;
      if (!breaker.isOpen()) await preloadPathHistory(syncContext);
      const first = payload.path && !breaker.isOpen()
        ? await runRequest("GET", target => navigate({ method: "GET", path: payload.path, headers: payload.headers }, target), { tabId: coordinator.workerId })
        : null;
      if (!breaker.isOpen() && host && typeof host.notices === "function") {
        const state = host.syncState();
        if (!state.fault && (state.exit === undefined || state.exit === 0) && state.notices > 0) {
          emitSyncNotices(host.notices({ action: "list" }).notices);
        }
      }
      return {
        compileMs: compiled - started,
        restored: bootInfo.restored,
        rehydrated: bootInfo.rehydrated,
        storageMs: bootInfo.storageMs,
        runtimeMs: bootInfo.runtimeMs,
        bootstrapMs: bootInfo.bootstrapMs,
        first,
        circuit: breaker.snapshot(),
        shell: bootInfo.shell,
        role: startedRole.role,
        storageMode: bootInfo.storageMode,
      };
    }

    // Follower path: leader already owns the hot AppHost and storage.
    const tabBoot = await coordinator.call("boot_tab", { path: payload.path, syncScope, syncHeaders, headers: payload.headers, trace: payload.trace }, { idempotent: true });
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
      circuit: tabBoot.circuit || breaker.snapshot(),
      shell: null,
      role: "follower",
      storageMode: tabBoot.storageMode,
    };
  }

  function shutdown({ announceBye = true } = {}) {
    streamLeader?.stop();
    streamLeader = null;
    clearTimeout(kickTimer);
    clearTimeout(fillTimer);
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
      if (type === "instant_record.visibility") {
        pageVisible = !!event.data.visible;
        streamLeader?.setVisible(pageVisible);
        return;
      }
      if (type === "instant_record.pagehide") {
        pageVisible = false;
        if (event.data.persisted) {
          pageSuspended = true;
          streamLeader?.suspend();
        } else {
          pageTornDown = true;
          shutdown({ announceBye: true });
        }
        return;
      }
      if (type === "instant_record.pageshow") {
        pageSuspended = false;
        pageVisible = !!event.data.visible;
        streamLeader?.resume(pageVisible);
        return;
      }
      if (type === "instant_record.bye") {
        shutdown({ announceBye: true });
        return;
      }
      if (type === "instant_record.clear_log") {
        history.length = 0;
        coordinator?.clearLog();
        return;
      }
      if (type === "instant_record.reset_circuit") {
        const result = coordinator
          ? await coordinator.call("reset_circuit", null, { idempotent: true })
          : await handleLeaderRpc("reset_circuit", null, { tabId: null });
        if (id != null) return postMessage({ id, result });
        return;
      }
      if (type === "instant_record.trace.configure") {
        const options = payload || event.data.options || {};
        const result = coordinator
          ? await coordinator.call("trace.configure", options, { idempotent: true })
          : await handleLeaderRpc("trace.configure", options, { tabId: null });
        if (id != null) return postMessage({ id, result });
        return;
      }
      if (type === "instant_record.trace.status") {
        const result = coordinator
          ? await coordinator.call("trace.status", null, { idempotent: true })
          : await handleLeaderRpc("trace.status", null, { tabId: null });
        if (id != null) return postMessage({ id, result });
        return;
      }
      if (type === "instant_record.trace.clear") {
        const result = coordinator
          ? await coordinator.call("trace.clear", null, { idempotent: true })
          : await handleLeaderRpc("trace.clear", null, { tabId: null });
        if (id != null) return postMessage({ id, result });
        return;
      }
      if (type === "instant_record.trace.export") {
        const options = payload || event.data.options || {};
        const trace = coordinator
          ? await coordinator.call("trace.export", options, { idempotent: true })
          : await handleLeaderRpc("trace.export", options, { tabId: null });
        if (id != null) return postMessage({ id, result: trace });
        postMessage({ type: "instant_record.trace.exported", trace });
        return;
      }
      if (type === "instant_record.configure_headers") {
        if (payload && typeof payload === "object") {
          syncHeaders = { ...syncHeaders, ...payload };
          if (coordinator && coordinator.role === "follower") {
            await coordinator.call("configure_headers", payload, { idempotent: true });
          }
        }
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
          postMessage({ type: "instant_record.debug_backlog", entries: history, streamOpen });
        }
        streamLeader?.setOfflineSimulated(!!effectiveSimulation().offline);
        if (isLeaderOrStandalone() && host && previous.offline && !localSimulation.offline && !effectiveSimulation().offline && !breaker.isOpen()) {
          drainRetry.delayMs = DRAIN_RETRY_BASE_MS;
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
    handleOffline,
    shutdown,
    fillStep,
    syncPass,
    get role() { return coordinator?.role || "idle"; },
    get storageMode() { return storage?.mode || coordinator?.storageMode || null; },
    get fillState() { return fillState; },
    get streamOpen() { return streamOpen; },
    get breaker() { return breaker; },
    get recorder() { return recorder; },
  };
}
