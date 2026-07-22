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
  await vm.evalAsync("InstantRecord.start");

  const seconds = parseInt(
    (await vm.evalAsync("InstantRecord.config.sync_interval")).toString(),
    10,
  );

  clearInterval(syncTimer);
  syncTimer = setInterval(tick, seconds * 1000);
  tick(); // initial drain + catch-up
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

self.addEventListener("activate", (event) => {
  console.log("[rails-web] Activate Service Worker");
});

self.addEventListener("install", (event) => {
  console.log("[rails-web] Install Service Worker");
  event.waitUntil(installApp().then(() => self.skipWaiting()));
});

const rackHandler = new RackHandler(initVM, { assumeSSL: true, async: true });

const BOOT_RESOURCES = ["/boot", "/boot.js", "/boot.html", "/rails.sw.js"];
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

  if (event.data.type === "reload-rails") {
    const progress = new Progress();
    await progress.attach(self);

    progress.updateStep("Reloading Rails application...");

    resetVM();
    await initVM(progress, { debug: event.data.debug });
  }
});
