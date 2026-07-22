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

  if (syncTimer) clearInterval(syncTimer);
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

  vm = await initRailsVM("/app.wasm", {
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
  if (syncTimer) clearInterval(syncTimer);
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

self.addEventListener("fetch", (event) => {
  // Cross-origin requests (e.g. the sync server) go straight to the network.
  if (new URL(event.request.url).origin !== self.location.origin) {
    return;
  }

  const bootResources = ["/boot", "/boot.js", "/boot.html", "/rails.sw.js"];

  if (
    bootResources.find((r) => new URL(event.request.url).pathname.endsWith(r))
  ) {
    console.log(
      "[rails-web] Fetching boot files from network:",
      event.request.url,
    );
    event.respondWith(fetch(event.request.url));
    return;
  }

  const viteResources = ["node_modules", "@vite"];

  if (viteResources.find((r) => event.request.url.includes(r))) {
    console.log(
      "[rails-web] Fetching Vite files from network:",
      event.request.url,
    );
    event.respondWith(fetch(event.request.url));
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
