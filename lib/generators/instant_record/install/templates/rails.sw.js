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

  return vm;
};

const resetVM = () => {
  vm = null;
};

// ---------------------------------------------------------------------------
// InstantRecord sync: outbox drain (HTTP POST) + SSE change stream.
// Ruby owns all sync semantics; JS only moves JSON across the network,
// because ruby.wasm cannot own fetch/EventSource itself.
// ---------------------------------------------------------------------------

// Where the authoritative Rails app lives. Same-origin is right when this PWA
// is served by the Rails app itself. When developing against the Vite dev
// server, point it at your Rails server instead:
//   const SYNC_SERVER = "http://localhost:3000/instant_record";
const SYNC_SERVER = `${self.location.origin}/instant_record`;

const notifyClients = async () => {
  const clients = await self.clients.matchAll();
  clients.forEach((client) => client.postMessage({ type: "records_changed" }));
};

let draining = false;

const drainOutbox = async () => {
  if (!vm || draining) return;
  draining = true;

  try {
    const pendingJson = (
      await vm.evalAsync("InstantRecord.pending_mutations_json")
    ).toString();
    const mutations = JSON.parse(pendingJson);
    if (mutations.length === 0) return;

    const response = await fetch(`${SYNC_SERVER}/mutations`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ mutations }),
    });
    if (!response.ok) throw new Error(`mutations POST failed: ${response.status}`);

    const { results } = await response.json();
    const resultsProc = await vm.evalAsync(
      "proc { |json| InstantRecord.apply_results(json.to_s) }"
    );
    await resultsProc.callAsync("call", vm.wrap(JSON.stringify(results)));
    await notifyClients();
    console.log(`[instant-record] drained ${mutations.length} mutation(s)`);
  } catch (e) {
    console.warn("[instant-record] drain failed (offline?)", e.message);
  } finally {
    draining = false;
  }
};

let ssePolling = false;

const pollChanges = async () => {
  if (!vm || ssePolling) return;
  ssePolling = true;

  try {
    const cursor = (await vm.evalAsync("InstantRecord.cursor")).toString();
    const response = await fetch(`${SYNC_SERVER}/events?after=${cursor}`, {
      headers: { Accept: "text/event-stream" },
    });
    if (!response.ok || !response.body) throw new Error(`events failed: ${response.status}`);

    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    let sawChange = false;

    const applyProc = await vm.evalAsync(
      "proc { |json| InstantRecord.apply_change(json.to_s) }"
    );

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });

      let sepIndex;
      while ((sepIndex = buffer.indexOf("\n\n")) >= 0) {
        const rawEvent = buffer.slice(0, sepIndex);
        buffer = buffer.slice(sepIndex + 2);

        const idLine = rawEvent.match(/^id: (.+)$/m);
        const dataLine = rawEvent.match(/^data: (.+)$/m);
        if (!dataLine) continue;

        const event = JSON.parse(dataLine[1]);
        if (idLine) event.cursor = parseInt(idLine[1], 10);

        await applyProc.callAsync("call", vm.wrap(JSON.stringify(event)));
        sawChange = true;
      }
    }

    if (sawChange) await notifyClients();
  } catch (e) {
    console.warn("[instant-record] event stream unavailable (offline?)", e.message);
  } finally {
    ssePolling = false;
  }
};

const startSyncLoop = () => {
  // The SSE window on the server is bounded (~25s); we reconnect immediately,
  // resuming from the persisted cursor. Drain retries piggyback on the timer.
  setInterval(() => {
    drainOutbox();
    pollChanges();
  }, 3000);
};

startSyncLoop();

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

  // Local writes enqueue outbox mutations; kick a drain right after.
  if (event.request.method !== "GET") {
    event.waitUntil(
      respond.then(() =>
        drainOutbox().catch((e) => console.warn("[instant-record]", e)),
      ),
    );
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
