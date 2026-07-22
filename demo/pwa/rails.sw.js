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

  progress?.updateStep("Initializing PGlite database...");
  db = await setupPGliteDatabase();
  progress?.updateStep("PGlite database created.");

  return db;
};

let vm = null;
let syncTimer = null;

// The whole sync loop lives in Ruby (InstantRecord.tick). Wasm Ruby cannot
// sleep without blocking the VM, so this shim provides the clock — nothing
// else. Ruby's single-flight guard makes overlapping ticks safe.
const tick = () => {
  if (!vm) return;
  vm.evalAsync("InstantRecord.tick").catch((e) =>
    console.warn("[instant-record] tick failed", e),
  );
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

  clearInterval(syncTimer);
  syncTimer = setInterval(tick, seconds * 1000);
  tick(); // initial drain + catch-up
};

// History fetches enter the VM here — via a page message, never from inside a
// Rack request — because a nested evalAsync at an asyncify suspension point
// is the known crash class. Ruby's single-flight guard answers busy while a
// sync tick is in flight; retry briefly instead of interleaving.
const fetchHistory = async (request, attempts = 8) => {
  if (!vm) return { ok: false, error: "vm not ready" };

  for (let attempt = 0; attempt < attempts; attempt++) {
    let reply;
    try {
      const raw = await vm.evalAsync(
        `InstantRecord.fetch_history_json(${JSON.stringify(JSON.stringify(request))})`,
      );
      reply = JSON.parse(raw.toString());
    } catch (e) {
      return { ok: false, error: String(e) };
    }
    if (!reply.busy) return reply;
    await new Promise((resolve) => setTimeout(resolve, 150 * (attempt + 1)));
  }

  return { ok: false, error: "sync busy" };
};

const initVM = async (progress, opts = {}) => {
  if (vm) return vm;

  if (!db) {
    await initDB(progress);
  }

  registerPGliteWasmInterface(self, db);

  let redirectConsole = true;

  const bootStartedAt = performance.now();

  // Fetch with revalidation: the browser happily serves a cached app.wasm to
  // a freshly installed service worker, pinning clients to a stale bundle
  // after a rebuild. `no-cache` revalidates via ETag — a 304 when unchanged,
  // fresh bytes after a deploy.
  progress?.updateStep("Loading WebAssembly module...");
  const wasmModule = await WebAssembly.compileStreaming(
    fetch("/app.wasm", { cache: "no-cache" }),
  );

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

  // Ensure schema is loaded (PGlite is async-only, so evalAsync)
  progress?.updateStep("Preparing database...");
  await vm.evalAsync("ActiveRecord::Tasks::DatabaseTasks.prepare_all");

  const bootMs = Math.round(performance.now() - bootStartedAt);
  console.log(`[instant-record] Rails VM boot + db prepare: ${bootMs}ms`);
  progress?.notify(`Rails VM boot + db prepare: ${bootMs}ms`);

  redirectConsole = false;

  await startSync();

  return vm;
};

const resetVM = () => {
  clearInterval(syncTimer);
  syncTimer = null;
  vm = null;
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
const BUILD_VERSION = "0f0724680b7f";

self.addEventListener("activate", (event) => {
  console.log(`[rails-web] Activate Service Worker (build ${BUILD_VERSION})`);
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
  console.log(`[rails-web] Install Service Worker (build ${BUILD_VERSION})`);
  event.waitUntil(installApp().then(() => self.skipWaiting()));
});

const rackHandler = new RackHandler(initVM, { assumeSSL: true, async: true });

const BOOT_RESOURCES = ["/boot", "/boot.js", "/boot.html", "/rails.sw.js", "/favicon.ico"];
const VITE_RESOURCES = ["node_modules", "@vite"];

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);

  // Cross-origin requests (e.g. the sync server) go straight to the network.
  if (url.origin !== self.location.origin) {
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

  // Local writes enqueue outbox mutations; sync right after.
  if (event.request.method !== "GET") {
    event.waitUntil(respond.then(() => tick()));
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

  if (event.data.type === "reload-rails") {
    const progress = new Progress();
    await progress.attach(self);

    progress.updateStep("Reloading Rails application...");

    resetVM();
    await initVM(progress, { debug: event.data.debug });
  }
});
