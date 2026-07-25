import {
  initRailsVM,
  Progress,
  registerPGliteWasmInterface,
  RackHandler,
} from "wasmify-rails";

import { setupPGliteDatabase } from "./database.js";

let db = null;

const initDB = async (progress) => {
  if (db) return db;

  bootStarted();
  const startedAt = performance.now();

  progress?.updateStep("Initializing PGlite database...");
  db = await setupPGliteDatabase();
  progress?.updateStep("PGlite database created.");

  bootPhase("pglite", { ms: since(startedAt) });

  return db;
};

let vm = null;

// --- Inspection and simulation ----------------------------------------------
// Ruby's transport reaches the network through globalThis.fetch (see
// Client::Transport::JsFetch), so wrapping it here is the one place that sees
// every request the sync loop makes to the server — and the one place that can
// delay or fail those requests without the sync code knowing. A page turns this
// on by posting instant_record.simulate; until then it is inert.

const sim = { report: false, offline: false, latencyMs: 0 };

// Kept here, not in the page: in a plain-Rails app every interaction is a
// navigation, which wipes any page-side buffer and races the message announcing
// the navigation itself. The worker outlives all of that, so a page that just
// loaded can ask for what it missed.
const REPORT_HISTORY = 150;
const history = [];

const report = (entry) => {
  const stamped = { ...entry, at: Date.now() };
  history.push(stamped);
  if (history.length > REPORT_HISTORY) history.shift();

  if (!sim.report) return;

  self.clients.matchAll({ type: "window" }).then((clients) => {
    clients.forEach((client) =>
      client.postMessage({ type: "instant_record.debug", entry: stamped }),
    );
  });
};

// Ruby-authored entries, same pipe. The VM knows what a sync pass actually did
// — "drained 3, 1 rejected: Body is too long" — where this worker only knows
// it saw a POST return 200. The gem's Client::Instrumentation forwards its
// ActiveSupport::Notifications events here as ready-made entries; the worker
// contributes transport, backlog, and delivery, never authorship.
self.instantRecordReport = (json) => {
  try {
    report(JSON.parse(json));
  } catch {
    // Narration must never break sync.
  }
};

// Assets arrive as a burst after every navigation. Worth knowing that the
// bundle serves its own asset pipeline — but once per page, as a total, not as
// a dozen lines that bury the sync flow. (They are re-requested each load
// rather than cached, which is why the burst repeats.)
const ASSET_BATCH_MS = 250;

let assetBatch = null;

const reportAssets = (ms) => {
  if (!sim.report) return;

  assetBatch ||= { count: 0, ms: 0, timer: null };
  assetBatch.count += 1;
  assetBatch.ms += ms;

  clearTimeout(assetBatch.timer);
  assetBatch.timer = setTimeout(() => {
    const { count, ms: total } = assetBatch;
    assetBatch = null;
    report({
      kind: "assets",
      path: `${count} served from the bundle`,
      ms: total,
    });
  }, ASSET_BATCH_MS);
};

const nativeFetch = globalThis.fetch.bind(globalThis);

globalThis.fetch = async (input, init) => {
  const href = typeof input === "string" ? input : input.url;
  const url = new URL(href, self.location.origin);

  // Only requests to the sync server are simulated. The app's own bundle and
  // assets are same-origin and must keep loading even while "offline" — going
  // offline means losing the server, not the local runtime.
  if (url.origin === self.location.origin) return nativeFetch(input, init);

  const method = (
    init?.method || (typeof input === "object" && input.method) || "GET"
  ).toUpperCase();
  const startedAt = performance.now();
  const elapsed = () => Math.round(performance.now() - startedAt);

  if (sim.latencyMs) {
    await new Promise((resolve) => setTimeout(resolve, sim.latencyMs));
  }

  if (sim.offline) {
    report({ kind: "sync", method, path: url.pathname, status: "offline" });
    throw new TypeError("Failed to fetch (simulated offline)");
  }

  try {
    const response = await nativeFetch(input, init);
    report({ kind: "sync", method, path: url.pathname, status: response.status, ms: elapsed() });
    return response;
  } catch (error) {
    report({ kind: "sync", method, path: url.pathname, status: "failed", ms: elapsed() });
    throw error;
  }
};

// --- Carrying writes up ------------------------------------------------------
// No heartbeat. A sync pass runs when there is a reason for one: a local write
// just happened, the app just booted, or the network came back. The only reason
// to come back unprompted is an outbox that still has something in it, so the
// pass reports what is left and we retry with backoff until it is empty. An idle
// client makes no requests at all beyond holding the change stream open.

const DRAIN_BACKOFF_CAP_MS = 30000;
// How long a burst is given to finish before one pass carries all of it. Short
// enough to be imperceptible — the write itself already rendered locally.
const SYNC_QUIET_MS = 50;

let drainTimer = null;
let drainBaseMs = 3000; // replaced with config.sync_interval once the VM is up
let drainDelayMs = drainBaseMs;

const syncNow = async () => {
  if (!vm) return;

  clearTimeout(drainTimer);
  drainTimer = null;

  const startedAt = performance.now();
  const reply = await enterVM("InstantRecord.tick_json");
  const ms = Math.round(performance.now() - startedAt);

  if (reply.error) console.warn("[instant-record] sync pass failed", reply.error);

  // Nothing queued: stop. This is what makes an idle tab silent.
  const pending = reply.pending ?? 0;
  if (reply.ok && pending === 0) {
    drainDelayMs = drainBaseMs;
    report({ kind: "sync-pass", path: "outbox empty, idle", ms });
    return;
  }

  report({
    kind: "sync-pass",
    path: `${pending} queued, retrying in ${Math.round(drainDelayMs / 1000)}s`,
    status: reply.ok ? undefined : "failed",
    ms,
  });

  drainTimer = setTimeout(syncNow, drainDelayMs);
  drainDelayMs = Math.min(drainDelayMs * 2, DRAIN_BACKOFF_CAP_MS);
};

// A fresh reason to sync resets the backoff — the previous delay was chosen for
// a failure that a new write or a reconnect has no bearing on.
//
// The short wait is this shim's only job here: Ruby coalesces requests that
// arrive while a pass is running (see InstantRecord::COALESCE_PASSES), but it
// cannot sleep to wait for ones that arrive *between* passes, because sleeping
// would block the VM. So a burst of writes settles into one pass rather than one
// pass each, and the batched drain then carries the whole burst in one request.
const syncSoon = () => {
  drainDelayMs = drainBaseMs;
  clearTimeout(drainTimer);
  drainTimer = setTimeout(syncNow, SYNC_QUIET_MS);
};

const startSync = async () => {
  // Boot-time window eviction runs only on cold boots. An idle-terminated
  // worker restarting under already-open tabs (which it still controls) must
  // not trim scrollback a reader is holding.
  const controlled = await self.clients.matchAll({ type: "window" });
  const coldBoot = controlled.length === 0;
  await vm.evalAsync(`InstantRecord.start(cold_boot: ${coldBoot})`);

  const seconds = parseInt(
    (await vm.evalAsync("InstantRecord.config.sync_interval")).toString(),
    10,
  );

  drainBaseMs = seconds * 1000;
  drainDelayMs = drainBaseMs;

  // The one unprompted pass: hydrates a fresh client, trims windows on a cold
  // boot, and clears anything an earlier session left queued.
  syncNow();

  // Not awaited: holds a stream for as long as the VM lives.
  streamChanges();
};

// --- The change stream -------------------------------------------------------
// Ruby cannot hold a tailing stream: every chunk it awaited would suspend the
// single-flight guard, starving outbox drains for the whole window. That is why
// its own poll asks for window=0. The worker has no such problem — it is plain
// JavaScript — so it holds the stream here and hands batches to Ruby. Inbound
// delivery is push, and reopening with ?after=<cursor> replays anything missed,
// which is why nothing needs to poll for changes any more.

const STREAM_RETRY_MS = 2000;

let streaming = false;
// Going offline has to sever the connection that is already open, not just fail
// the next one — a held stream would otherwise keep delivering for the rest of
// its window and make the simulation look broken.
let streamAbort = null;

// Enter the VM for one guarded, JSON-returning call, retrying while a sync pass
// holds the single-flight guard. Every entry point the worker uses answers
// {busy: true} rather than re-entering.
const enterVM = async (expression, attempts = 8) => {
  for (let attempt = 0; attempt < attempts; attempt++) {
    let reply;
    try {
      reply = JSON.parse((await vm.evalAsync(expression)).toString());
    } catch (e) {
      return { ok: false, error: String(e) };
    }
    if (!reply.busy) return reply;
    await new Promise((resolve) => setTimeout(resolve, 150 * (attempt + 1)));
  }
  return { ok: false, busy: true };
};

const runStream = async () => {
  const endpoint = (await vm.evalAsync("InstantRecord.endpoint")).toString();
  const cursor = (await vm.evalAsync("InstantRecord.cursor")).toString();
  // Deliberately the wrapped fetch: the stream is a sync-server request, so
  // "offline" must break it like any other and let the poll take over.
  streamAbort = new AbortController();
  const response = await fetch(`${endpoint}/events?after=${cursor}`, {
    signal: streamAbort.signal,
  });
  if (!response.ok) throw new Error(`stream -> ${response.status}`);

  // Also discards any half-received frame from the connection that just died.
  await enterVM("InstantRecord.stream_opened_json");
  streaming = true;
  report({ kind: "stream", path: `connected, tailing from ${cursor}`, streamOpen: true });

  // Reaching the server proves the network is back, which is the other reason a
  // stalled outbox deserves an immediate retry rather than waiting out a backoff.
  syncSoon();

  const reader = response.body.getReader();
  const decoder = new TextDecoder();

  // Read bytes, hand over text. Framing the SSE wire format is Ruby's job — it
  // already has a parser for it (Transport::SseParser), and a second one here
  // would be an untested copy free to drift. A frame split across chunks is
  // buffered on that side until it is whole.
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;

    const chunk = decoder.decode(value, { stream: true });
    if (!chunk) continue;

    const encoded = btoa(unescape(encodeURIComponent(chunk)));
    const consumed = await enterVM(`InstantRecord.consume_stream_b64("${encoded}")`);
    if (!consumed.applied) continue;

    report({
      kind: "stream",
      path: `${consumed.applied} pushed → applied, cursor ${consumed.cursor}`,
      status: consumed.ok ? 200 : "failed",
    });
  }
};

// One stream at a time, reopened for as long as the VM is alive. A failure just
// means the tick's poll is the delivery path until the next attempt succeeds.
const streamChanges = async () => {
  for (;;) {
    if (!vm) return;

    try {
      await runStream();
      report({ kind: "stream", path: "window closed, reopening", streamOpen: false });
    } catch (error) {
      report({
        kind: "stream",
        path: "unavailable — polling instead",
        status: "failed",
        streamOpen: false,
      });
      await new Promise((resolve) => setTimeout(resolve, STREAM_RETRY_MS));
    } finally {
      if (streaming) {
        streaming = false;
        await enterVM("InstantRecord.stream_closed_json");
      }
    }
  }
};

// History fetches enter the VM here — via a page message, never from inside a
// Rack request — because a nested evalAsync at an asyncify suspension point
// is the known crash class. Ruby's single-flight guard answers busy while a
// sync tick is in flight; retry briefly instead of interleaving.
const fetchHistory = async (request, attempts = 8) => {
  if (!vm) return { ok: false, error: "vm not ready" };

  // Base64 the request before it enters Ruby source: the base64 alphabet
  // has none of Ruby's string-literal metacharacters, so an untrusted page
  // message can't break out of the string or trigger #{} interpolation.
  // Passing raw JSON here would be a code-injection sink.
  const encoded = btoa(
    unescape(encodeURIComponent(JSON.stringify(request))),
  );

  const startedAt = performance.now();

  for (let attempt = 0; attempt < attempts; attempt++) {
    let reply;
    try {
      const raw = await vm.evalAsync(
        `InstantRecord.fetch_history_b64("${encoded}")`,
      );
      reply = JSON.parse(raw.toString());
    } catch (e) {
      report({ kind: "history", path: "fetch_history", status: "failed" });
      return { ok: false, error: String(e) };
    }
    if (!reply.busy) {
      // Success narrates itself from Ruby (fetch_history.instant_record →
      // instantRecordReport); this side only reports what only it can see —
      // the eval failing outright, or the busy/retry dance around the
      // single-flight guard.
      if (!reply.ok) {
        report({
          kind: "history",
          path: "fetch_history",
          status: "failed",
          ms: Math.round(performance.now() - startedAt),
        });
      }
      return reply;
    }
    report({ kind: "history", path: "fetch_history → busy, retrying", status: "busy" });
    await new Promise((resolve) => setTimeout(resolve, 150 * (attempt + 1)));
  }

  // Retries exhausted while a sync pass held the VM: transient, not offline.
  return { ok: false, busy: true, error: "sync busy" };
};

// --- The boot ledger ---------------------------------------------------------
// A first boot downloads ~60MB of Ruby, compiles it, opens a Postgres, boots
// Rails and prepares a schema. Behind one line of splash copy that wait reads as
// broken; itemised, it reads as expensive and understood. So each phase is
// timed here and announced as it lands.
//
// This is the browser's own instrumentation, not sync logic: the worker is the
// only place that sees the bundle arrive and the VM come up. It reports numbers
// only — the words belong to the page. Nothing is estimated: a figure this side
// cannot measure is sent as null, and the page leaves that line out.

// Only this build produces ledger messages, and it says so out loud. An edited
// worker can fail to reach the browser silently (the dev worker's URL never
// changes), so anything measuring the worker can check what it is talking to
// instead of assuming.
const LEDGER_VERSION = "boot-ledger-1";

const boot = { at: null, startedAt: null, entries: [], totalMs: null };

const announce = async (message) => {
  // includeUncontrolled: during install this worker controls nothing yet, and
  // the splash waiting on it is precisely the client that needs these.
  const clients = await self.clients.matchAll({
    includeUncontrolled: true,
    type: "window",
  });
  clients.forEach((client) => client.postMessage(message));
};

// Whichever entry point gets there first owns the clock: install boots the VM,
// but so does the first Rack request after an idle worker was terminated.
const bootStarted = () => {
  if (boot.startedAt !== null) return;

  boot.at = Date.now();
  boot.startedAt = performance.now();
  boot.entries = [];
  boot.totalMs = null;
};

const since = (mark) => Math.round(performance.now() - mark);

const bootPhase = (phase, detail) => {
  const entry = { phase, ...detail };
  boot.entries.push(entry);
  announce({ type: "instant_record.boot_phase", entry, ledger: LEDGER_VERSION });
};

const bootLedger = () => ({
  ledger: LEDGER_VERSION,
  build: BUILD_VERSION,
  at: boot.at,
  entries: boot.entries,
  totalMs: boot.totalMs,
});

const initVM = async (progress, opts = {}) => {
  if (vm) return vm;

  bootStarted();

  if (!db) {
    await initDB(progress);
  }

  registerPGliteWasmInterface(self, db);

  let redirectConsole = true;

  // Fetch with revalidation: the browser happily serves a cached app.wasm to
  // a freshly installed service worker, pinning clients to a stale bundle
  // after a rebuild. `no-cache` revalidates via ETag — a 304 when unchanged,
  // fresh bytes after a deploy.
  progress?.updateStep("Loading WebAssembly module...");
  const wasmUrl = new URL("/app.wasm", self.location.origin).href;
  const requestedAt = performance.now();
  const response = await fetch(wasmUrl, { cache: "no-cache" });

  // Count the bytes on their way into the compiler rather than trusting a size
  // written down at build time — that number drifts, this one cannot. The
  // stream still feeds compileStreaming, so compiling continues to overlap the
  // download and the transform costs nothing measurable.
  let bytes = 0;
  let lastByteAt = null;
  const counted = response.body.pipeThrough(
    new TransformStream({
      transform(chunk, controller) {
        bytes += chunk.byteLength;
        controller.enqueue(chunk);
      },
      flush() {
        lastByteAt = performance.now();
      },
    }),
  );

  const wasmModule = await WebAssembly.compileStreaming(
    new Response(counted, { headers: { "content-type": "application/wasm" } }),
  );
  const compiledAt = performance.now();

  // Whether those bytes crossed the network is the browser's own accounting,
  // not something to infer: `transferSize` counts what came over the wire, so
  // 0 is a cache hit and header-sized is a revalidated one. `no-cache` above
  // means even a warm boot re-asks, which is why the comparison is against
  // encodedBodySize rather than zero. Resource timing is not guaranteed inside
  // a worker — without it, cached stays null and the page says nothing.
  const timing = performance.getEntriesByName(wasmUrl).pop();
  const wireBytes = timing ? timing.encodedBodySize || null : null;
  const cached = timing
    ? timing.transferSize === 0 ||
      (timing.encodedBodySize > 0 && timing.transferSize < timing.encodedBodySize)
    : null;

  bootPhase("bundle", {
    ms: Math.round((lastByteAt ?? compiledAt) - requestedAt),
    bytes,
    wireBytes,
    cached,
  });

  // Streaming compilation finishes shortly after the last byte; that tail is
  // the only part of the compile that is not hidden behind the download.
  bootPhase("compile", { ms: Math.round(compiledAt - (lastByteAt ?? requestedAt)) });

  const vmStartedAt = performance.now();

  vm = await initRailsVM(wasmModule, {
    database: { adapter: "pglite" },
    async: true,
    progressCallback: (step) => {
      progress?.updateStep(step);
    },
    outputCallback: (output) => {
      if (!redirectConsole) return;
      progress?.notify(output);
    },
    ...opts,
  });

  bootPhase("vm", { ms: since(vmStartedAt) });

  // Ensure schema is loaded (PGlite is async-only, so evalAsync). Not a bare
  // DatabaseTasks.prepare_all: the app's migrations are invisible from this VM's
  // working directory, so catching an existing local database up to a schema
  // that has grown since is Ruby's job — InstantRecord::LocalSchema.
  const schemaStartedAt = performance.now();
  progress?.updateStep("Preparing database...");
  await vm.evalAsync("InstantRecord.prepare_database!");

  bootPhase("schema", { ms: since(schemaStartedAt) });

  boot.totalMs = Math.round(performance.now() - boot.startedAt);
  console.log(
    `[instant-record] boot ${boot.totalMs}ms (build ${BUILD_VERSION}, ${LEDGER_VERSION})`,
  );
  progress?.notify(`Rails VM boot + db prepare: ${boot.totalMs}ms`);
  announce({ type: "instant_record.boot_done", ledger: bootLedger() });

  redirectConsole = false;

  await startSync();

  return vm;
};

const resetVM = () => {
  clearTimeout(drainTimer);
  drainTimer = null;
  // The stream loop and any pending retry both bail once the VM is gone.
  vm = null;
  // The next boot is a boot of its own, and gets its own ledger.
  boot.startedAt = null;
};

// Half of a cold boot on demand — measuring one used to mean the DevTools
// "clear site data" ritual, so it was never repeated.
//
// This side lets go of everything: the held change stream (a pending fetch keeps
// this worker alive, and a live worker is what blocks the database delete), the
// PGlite handle, the caches, and finally the registration, so the page that
// reloads next comes back uncontrolled and installs a worker from scratch.
//
// Deleting the database itself is deliberately not done here. IndexedDB will not
// delete a database while anything holds it open, and closing PGlite does not
// release the handle its wasm filesystem keeps — only this worker's death does.
// So the page deletes it on the next load, once this worker is gone; a page that
// does not bother still gets a fresh worker on the data that is already there.
// What nothing can clear is the browser's own HTTP cache, which may still hold
// app.wasm — hence the ledger measuring where the bundle came from instead of
// assuming a wipe implies a download.
const wipeLocalData = async () => {
  streamAbort?.abort();
  resetVM();

  const open = db;
  db = null;
  await open?.close();

  await Promise.all((await caches.keys()).map((key) => caches.delete(key)));
  await self.registration.unregister();
};

const installApp = async () => {
  const progress = new Progress();
  await progress.attach(self);

  await initDB(progress);
  await initVM(progress);
};

// Stamped by instant_record:build with the app.wasm digest. A rebuild
// changes this constant, which changes the service worker's bytes, which
// makes the browser install the new worker on the next navigation — that is
// the whole update mechanism for already-installed clients.
const BUILD_VERSION = "ee11f6812b82";

self.addEventListener("activate", (event) => {
  console.log(
    `[rails-web] Activate Service Worker (build ${BUILD_VERSION}, ${LEDGER_VERSION})`,
  );
  // Take over open tabs immediately and reload them onto the new bundle;
  // without this, old tabs keep the previous worker's VM forever.
  event.waitUntil(
    self.clients.claim().then(async () => {
      const clients = await self.clients.matchAll({ type: "window" });
      clients.forEach((client) => client.postMessage({ type: "sw_updated" }));
    }),
  );
});

self.addEventListener("install", (event) => {
  console.log(
    `[rails-web] Install Service Worker (build ${BUILD_VERSION}, ${LEDGER_VERSION})`,
  );
  event.waitUntil(installApp().then(() => self.skipWaiting()));
});

const rackHandler = new RackHandler(initVM, { assumeSSL: true, async: true });

const BOOT_RESOURCES = ["/boot", "/boot.js", "/boot.html", "/rails.sw.js", "/favicon.ico"];
const VITE_RESOURCES = ["node_modules", "@vite"];
const VITE_ASSETS = ["/assets/pglite-", "/assets/boot-"];

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);

  // Cross-origin requests (e.g. the sync server) go straight to the network.
  if (url.origin !== self.location.origin) {
    return;
  }

  // Vite's hashed output shares /assets/ with Rails' Propshaft assets, which
  // Rack-in-Wasm serves from the bundle. Match Vite's files by name — a
  // blanket /assets/ bypass 404s every stylesheet and Stimulus controller.
  if (VITE_ASSETS.some((prefix) => url.pathname.startsWith(prefix))) {
    console.log("[rails-web] Fetching Vite asset from network:", url.href);
    event.respondWith(fetch(event.request));
    return;
  }

  if (BOOT_RESOURCES.some((r) => url.pathname.endsWith(r))) {
    console.log("[rails-web] Fetching boot files from network:", url.href);
    event.respondWith(fetch(event.request.url));
    return;
  }

  if (VITE_RESOURCES.some((r) => url.href.includes(r))) {
    console.log("[rails-web] Fetching Vite files from network:", url.href);
    event.respondWith(fetch(event.request.url));
    return;
  }

  // Requests marked ?instant_record_network=1 bypass the local runtime and go
  // to the real server — for actions whose writes must land on the
  // authoritative change log (e.g. a demo reset) even when served same-origin.
  if (url.searchParams.has("instant_record_network")) {
    console.log("[rails-web] Passing request to network:", url.href);
    // fetch(event.request) preserves the method and body (POSTs included).
    event.respondWith(fetch(event.request));
    return;
  }

  const respond = rackHandler.handle(event.request);

  // Reported from here rather than from the page, because a form submission and
  // a navigation are not window.fetch calls — wrapping fetch in the page misses
  // the entire plain-Rails interaction model, and the first page load with it.
  //
  if (sim.report) {
    const startedAt = performance.now();
    const isAsset = url.pathname.startsWith("/assets/");

    event.waitUntil(
      respond
        .then((response) => {
          const ms = Math.round(performance.now() - startedAt);
          if (isAsset) return reportAssets(ms);

          report({
            kind: "local",
            method: event.request.method,
            path: url.pathname + url.search,
            status: response.status,
            ms,
          });
        })
        .catch(() => {}),
    );
  }

  // A local write enqueues an outbox mutation, and that is the main reason a
  // sync pass ever runs — there is no timer waiting to notice it.
  if (event.request.method !== "GET") {
    event.waitUntil(respond.then(() => syncSoon()));
  }

  return event.respondWith(respond);
});

self.addEventListener("message", async (event) => {
  console.log("[rails-web] Received worker message:", event.data);

  if (event.data.type === "instant_record.fetch_history") {
    const reply = await fetchHistory(event.data.request);
    event.ports[0]?.postMessage(reply);
    return;
  }

  // A page that was not open for the boot it wants to report on asks for the
  // ledger here — /receipts, or any warm visit where the splash never appeared.
  // totalMs is null while a boot is still running.
  if (event.data.type === "instant_record.boot_ledger") {
    event.source?.postMessage({
      type: "instant_record.boot_done",
      ledger: bootLedger(),
    });
    return;
  }

  if (event.data.type === "instant_record.wipe_local_data") {
    await wipeLocalData();
    event.ports[0]?.postMessage({ ok: true });
    return;
  }

  // Clearing has to reach the buffer, not just the page's copy of it.
  if (event.data.type === "instant_record.clear_log") {
    history.length = 0;
    return;
  }

  // Inspector controls: report toggles the event stream, offline and latencyMs
  // simulate a bad network on the sync server only.
  if (event.data.type === "instant_record.simulate") {
    const wasOffline = sim.offline;
    const before = `${sim.offline}/${sim.latencyMs}`;
    Object.assign(sim, event.data.settings || {});

    // Cut a live stream the moment the network is "lost".
    if (sim.offline && !wasOffline) streamAbort?.abort();

    // Only worth a line when something actually changed: every page load
    // re-states its settings, and logging that is pure noise.
    if (`${sim.offline}/${sim.latencyMs}` !== before) {
      report({
        kind: "sim",
        path: `offline: ${sim.offline}, latency: ${sim.latencyMs}ms`,
        streamOpen: streaming,
      });
    }

    // Only when asked. A page requests this once, on load: replaying it later
    // would replace a log that has since accumulated entries of its own.
    if (event.data.backlog) {
      event.source?.postMessage({
        type: "instant_record.debug_backlog",
        entries: history,
        streamOpen: streaming,
      });
    }
    return;
  }

  if (event.data.type === "reload-rails") {
    const progress = new Progress();
    await progress.attach(self);

    progress.updateStep("Reloading Rails application...");

    resetVM();
    await initVM(progress, { debug: event.data.debug });
  }
});
