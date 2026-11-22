import assert from "node:assert/strict";
import { test } from "node:test";
import { createWorkerRuntime } from "./reactor-runtime.js";

// Shared simulated browser environment: OPFS, IndexedDB, Web Locks, BroadcastChannel, and FakeAppHost.
function createTestEnvironment({ opfsUnavailable = false, seedIdbBytes = null, seedMeta = {} } = {}) {
  // 1. In-memory IndexedDB files store per scope
  const idbStores = new Map();
  function getStore(scope) {
    const key = scope || "__default__";
    if (!idbStores.has(key)) {
      const map = new Map(Object.entries(seedMeta));
      if (seedIdbBytes && !scope) map.set("development.sqlite3", new Uint8Array(seedIdbBytes));
      idbStores.set(key, map);
    }
    return idbStores.get(key);
  }

  function makeIdbForWorker() {
    let activeStore = null;
    return {
      openSnapshot(scope) {
        activeStore = getStore(scope);
      },
      async withFiles(_mode, op) {
        const snapshot = new Map(activeStore);
        const get = async key => activeStore.get(key);
        const put = (key, val) => activeStore.set(key, val);
        const del = key => activeStore.delete(key);
        try {
          return await op(get, put, del);
        } catch (err) {
          // Roll back on transaction abort.
          activeStore.clear();
          for (const [k, v] of snapshot) activeStore.set(k, v);
          throw err;
        }
      },
    };
  }

  // 2. Shared OPFS filesystem with exclusive sync handle enforcement
  const opfsTree = new Map();
  const openHandles = new Set();
  const opfsStats = { pageWrites: 0, flushes: 0 };

  function makeOpfsDir(map, pathPrefix = "") {
    return {
      async getDirectoryHandle(name, { create = false } = {}) {
        if (!map.has(name)) {
          if (!create) throw Object.assign(new Error("NotFound"), { name: "NotFoundError" });
          map.set(name, new Map());
        }
        return makeOpfsDir(map.get(name), pathPrefix + "/" + name);
      },
      async getFileHandle(name, { create = false } = {}) {
        if (!map.has(name)) {
          if (!create) throw Object.assign(new Error("NotFound"), { name: "NotFoundError" });
          map.set(name, { bytes: new Uint8Array(0) });
        }
        const entry = map.get(name);
        const fullKey = pathPrefix + "/" + name;
        return {
          async createSyncAccessHandle() {
            if (opfsUnavailable) throw Object.assign(new Error("Private mode"), { name: "SecurityError" });
            if (openHandles.has(fullKey)) {
              throw Object.assign(new Error("Already locked"), { name: "NoModificationAllowedError" });
            }
            openHandles.add(fullKey);
            let closed = false;
            return {
              getSize() { return entry.bytes.byteLength; },
              read(buf, { at = 0 } = {}) {
                const dst = new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
                if (at >= entry.bytes.byteLength) return 0;
                const slice = entry.bytes.subarray(at, at + dst.byteLength);
                dst.set(slice);
                return slice.byteLength;
              },
              write(buf, { at = 0 } = {}) {
                opfsStats.pageWrites++;
                const src = new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
                const end = at + src.byteLength;
                if (end > entry.bytes.byteLength) {
                  const grown = new Uint8Array(end);
                  grown.set(entry.bytes);
                  entry.bytes = grown;
                }
                entry.bytes.set(src, at);
                return src.byteLength;
              },
              truncate(size) {
                entry.bytes = size < entry.bytes.byteLength ? entry.bytes.slice(0, size) : new Uint8Array(size);
              },
              flush() { opfsStats.flushes++; },
              close() {
                if (closed) return;
                closed = true;
                openHandles.delete(fullKey);
              },
            };
          },
        };
      },
      async removeEntry(name) { map.delete(name); },
    };
  }

  const storageApi = {
    async getDirectory() {
      if (opfsUnavailable) throw Object.assign(new Error("Private mode"), { name: "SecurityError" });
      return makeOpfsDir(opfsTree);
    },
  };

  class FakePagedSyncOPFSFile {
    constructor(handle) { this.handle = handle; }
    byteLength() { return this.handle.getSize(); }
    readAll() {
      const buf = new Uint8Array(this.handle.getSize());
      this.handle.read(buf, { at: 0 });
      return buf;
    }
    writeAll(bytes) {
      this.handle.truncate(0);
      if (bytes.byteLength) this.handle.write(bytes, { at: 0 });
      this.handle.flush();
    }
    truncate(size = 0) { this.handle.truncate(size); this.handle.flush(); }
    flush() { this.handle.flush(); }
    close() { this.handle.close(); }
  }

  // 3. Shared Web Locks + BroadcastChannel bus
  const held = new Map();
  const queues = new Map();
  const channels = new Map();

  function grantNext(name) {
    if (held.has(name)) return;
    const queue = queues.get(name);
    if (!queue || queue.length === 0) return;
    const waiter = queue.shift();
    held.set(name, { name });
    Promise.resolve()
      .then(() => waiter.callback({ name }))
      .then(
        val => { held.delete(name); grantNext(name); waiter.resolve(val); },
        err => { held.delete(name); grantNext(name); waiter.reject(err); },
      );
  }

  const locks = {
    request(name, optionsOrCb, maybeCb) {
      const options = typeof optionsOrCb === "function" ? {} : optionsOrCb;
      const cb = typeof optionsOrCb === "function" ? optionsOrCb : maybeCb;
      if (options.ifAvailable) {
        if (held.has(name)) return Promise.resolve().then(() => cb(null));
        held.set(name, { name });
        return Promise.resolve().then(() => cb({ name })).finally(() => {
          held.delete(name);
          grantNext(name);
        });
      }
      return new Promise((resolve, reject) => {
        if (!queues.has(name)) queues.set(name, []);
        queues.get(name).push({ callback: cb, resolve, reject });
        grantNext(name);
      });
    },
    async query() {
      await new Promise(resolve => setTimeout(resolve, 0));
      return { held: [...held.values()], pending: [] };
    },
  };

  function createChannel(name) {
    if (!channels.has(name)) channels.set(name, new Set());
    const peers = channels.get(name);
    let closed = false;
    const channel = {
      onmessage: null,
      postMessage(data) {
        if (closed) return;
        const cloned = structuredClone(data);
        for (const other of [...peers]) {
          if (other === channel) continue;
          queueMicrotask(() => {
            if (other.onmessage) other.onmessage({ data: structuredClone(cloned) });
          });
        }
      },
      close() {
        if (closed) return;
        closed = true;
        peers.delete(channel);
      },
    };
    peers.add(channel);
    return channel;
  }

  // 4. Fake AppHost storing JSON state directly inside its mounted OPFS inode or in-memory bytes
  const hostMetrics = { instances: 0, databaseBytesCalls: 0, databaseSizeCalls: 0, simulatedDbSize: 0, failMigration: false };

  class FakeAppHost {
    constructor(module, { env = {} } = {}) {
      hostMetrics.instances++;
      this.module = module;
      this.env = env;
      this.cookies = new Map();
      this.inode = null;
      this.memBytes = null;
      this.schemaVersion = 0;
      this.state = { items: [], cursor: 1, bootstrapped: true, historyPages: 0 };
    }
    mountDatabase(inode, schemaVersion = 0) {
      this.inode = inode;
      this.schemaVersion = schemaVersion;
    }
    restoreDatabase(bytes, schemaVersion = 0) {
      this.memBytes = new Uint8Array(bytes);
      this.schemaVersion = schemaVersion;
    }
    ensureBooted() {
      const raw = this.inode ? this.inode.readAll() : this.memBytes;
      if (raw && raw.byteLength > 0) {
        const text = new TextDecoder().decode(raw);
        this.state = JSON.parse(text);
      }
      if (hostMetrics.failMigration) {
        // Mutate storage before failing to prove rollback restores pre-migration bytes.
        this._persist({ ...this.state, corruptedByFailedMigration: true });
        throw new Error("Simulated migration failure");
      }
      this._persist(this.state);
    }
    _persist(state) {
      this.state = state;
      const encoded = new TextEncoder().encode(JSON.stringify(state));
      if (this.inode) {
        this.inode.writeAll(encoded);
      } else {
        this.memBytes = encoded;
      }
    }
    databaseSize() {
      hostMetrics.databaseSizeCalls++;
      if (hostMetrics.simulatedDbSize > 0) return hostMetrics.simulatedDbSize;
      return this.inode ? this.inode.byteLength() : (this.memBytes?.byteLength || 0);
    }
    databaseBytes() {
      hostMetrics.databaseBytesCalls++;
      return this.inode ? this.inode.readAll() : this.memBytes;
    }
    flushDatabase() {
      this.inode?.flush();
    }
    request(method, path, { body = "" } = {}) {
      if (method === "POST" && path === "/items") {
        const next = { ...this.state, items: [...this.state.items, body] };
        this._persist(next);
        return { status: 201, headers: [], body: "created:" + body, exit: 0, errors: [] };
      }
      return { status: 200, headers: [], body: JSON.stringify(this.state.items), exit: 0, errors: [] };
    }
    syncPlan() { return { push: "", bootstrap: false }; }
    sync() { return { changed: false, pending: 0, cursor: this.state.cursor, notified: false, changes: null }; }
    syncState() { return { bootstrapped: true, cursor: this.state.cursor, pending: 0, identity: "" }; }
    consumeStream() { return { applied: 0, cursor: this.state.cursor, bootstrapped: true, notified: false, changes: null }; }
    history(_key, response = "") {
      if (!response) return { ok: false, applied: 0, has_more: true };
      const page = JSON.parse(response);
      this._persist({ ...this.state, historyPages: this.state.historyPages + 1 });
      return { ok: true, applied: page.records.length, has_more: page.has_more };
    }
  }

  function spawnWorker({ envOverrides = {}, fetchImpl } = {}) {
    const idb = makeIdbForWorker();
    const messages = [];
    const runtime = createWorkerRuntime({
      env: {
        VITE_SCHEMA_VERSION: "2",
        VITE_SCHEMA_BASELINE: "1",
        VITE_MIGRATION_HISTORY: JSON.stringify({ "1": "h1", "2": "h2" }),
        VITE_SCHEMA_DIGEST: "digest-v2",
        VITE_SOURCE_VERSION: "v2",
        VITE_SHARED_INBOX_DEMO: "1",
        ...envOverrides,
      },
      AppHost: FakeAppHost,
      PagedSyncOPFSFile: FakePagedSyncOPFSFile,
      openSnapshot: idb.openSnapshot,
      withFiles: idb.withFiles,
      locks,
      storageApi,
      createChannel,
      fetchImpl: fetchImpl || (async () => ({ status: 200, ok: true, text: async () => "{}" })),
      postMessage: msg => messages.push(msg),
      origin: "http://demo.test",
      pollIntervalMs: 0,
      fillInitialDelayMs: 60000,
    });

    let seq = 1;
    function rpc(type, payload) {
      const id = seq++;
      return new Promise((resolve, reject) => {
        const before = messages.length;
        runtime.handleMessage({ data: { id, type, payload } }).then(() => {
          const reply = messages.slice(before).find(m => m.id === id);
          if (!reply) return reject(new Error("Missing reply for " + type));
          if (reply.error) return reject(new Error(reply.error));
          resolve(reply.result);
        }, reject);
      });
    }

    return { runtime, messages, rpc };
  }

  return { spawnWorker, hostMetrics, opfsStats, opfsTree, idbStores, openHandles };
}

test("two tabs share one hot OPFS leader AppHost with zero databaseBytes dumps and seamless crash failover", async () => {
  const env = createTestEnvironment();
  const tab1 = env.spawnWorker();
  const tab2 = env.spawnWorker();

  const b1 = await tab1.rpc("boot", { module: {}, path: "/todo", scope: "s1" });
  const b2 = await tab2.rpc("boot", { module: {}, path: "/todo", scope: "s1" });

  assert.equal(b1.role, "leader");
  assert.equal(b1.storageMode, "opfs");
  assert.equal(b2.role, "follower");
  assert.equal(b2.storageMode, "opfs");
  assert.equal(env.hostMetrics.instances, 1, "follower does not instantiate a second AppHost");

  // Follower writes a record -> served by leader on OPFS without rebooting AppHost or dumping whole DB.
  const write = await tab2.rpc("request", { method: "POST", path: "/items", body: "from-tab-2" });
  assert.equal(write.status, 201);
  assert.equal(env.hostMetrics.instances, 1, "peer edit does not reboot AppHost");
  assert.equal(env.hostMetrics.databaseBytesCalls, 0, "OPFS writes never serialize whole databaseBytes()");
  assert.ok(env.opfsStats.flushes >= 1, "OPFS writes flush to disk");

  // Leader sees the record immediately and received records_changed.
  const read1 = await tab1.rpc("request", { method: "GET", path: "/items" });
  assert.deepEqual(JSON.parse(read1.body), ["from-tab-2"]);
  assert.ok(tab1.messages.some(m => m.type === "records_changed"));

  // Crash Tab 1 abruptly (without leader_bye): Tab 2 promotes over the same OPFS file and preserves writes.
  tab1.runtime.shutdown({ announceBye: false });
  await new Promise(resolve => setTimeout(resolve, 40));

  assert.equal(tab2.runtime.role, "leader");
  assert.equal(env.hostMetrics.instances, 2, "failover boots one new leader AppHost");
  assert.equal(tab2.runtime.storageMode, "opfs");

  const readAfterFailover = await tab2.rpc("request", { method: "GET", path: "/items" });
  assert.deepEqual(JSON.parse(readAfterFailover.body), ["from-tab-2"]);

  const writeAfterFailover = await tab2.rpc("request", { method: "POST", path: "/items", body: "after-failover" });
  assert.equal(writeAfterFailover.status, 201);
  const readFinal = await tab2.rpc("request", { method: "GET", path: "/items" });
  assert.deepEqual(JSON.parse(readFinal.body), ["from-tab-2", "after-failover"]);

  tab2.runtime.shutdown();
});

test("legacy IndexedDB snapshot migrates once to OPFS and removes legacy blob after boot", async () => {
  const legacyBytes = new TextEncoder().encode(JSON.stringify({ items: ["legacy-row"], cursor: 5, bootstrapped: true, historyPages: 0 }));
  const env = createTestEnvironment({
    seedIdbBytes: legacyBytes,
    seedMeta: {
      rails_schema_version: 2,
      snapshot_revision: 7,
      schema_digest: "digest-v2",
      migration_history: { "1": "h1", "2": "h2" },
    },
  });

  const tab = env.spawnWorker();
  const booted = await tab.rpc("boot", { module: {}, path: "/todo", scope: "s1" });
  assert.equal(booted.storageMode, "opfs");
  assert.equal(booted.restored, true);

  const read = await tab.rpc("request", { method: "GET", path: "/items" });
  assert.deepEqual(JSON.parse(read.body), ["legacy-row"]);
  assert.equal(env.idbStores.get("__default__").has("development.sqlite3"), false, "legacy IDB blob reclaimed after OPFS boot");

  tab.runtime.shutdown();
});

test("failed schema migration in OPFS rolls back exact SQLite bytes and leaves IDB version untouched", async () => {
  const v1Bytes = new TextEncoder().encode(JSON.stringify({ items: ["keep-me"], cursor: 3, bootstrapped: true, historyPages: 0 }));
  const env = createTestEnvironment({
    seedIdbBytes: v1Bytes,
    seedMeta: {
      rails_schema_version: 1,
      snapshot_revision: 4,
      schema_digest: "digest-v1",
      migration_history: { "1": "h1" },
    },
  });
  env.hostMetrics.failMigration = true;

  const tab = env.spawnWorker();
  await assert.rejects(() => tab.rpc("boot", { module: {}, path: "/todo", scope: "s1" }), /Simulated migration failure/);

  const stored = env.opfsTree.get("instant-record-spinel").get("default").get("development.sqlite3").bytes;
  assert.deepEqual(stored, v1Bytes, "OPFS bytes restored verbatim on failed migration");
  assert.equal(env.idbStores.get("__default__").get("rails_schema_version"), 1);
  assert.equal(env.idbStores.get("__default__").get("snapshot_revision"), 4);

  tab.runtime.shutdown();
});

test("Safari Private Mode falls back cleanly to IndexedDB and keeps 24 MB fill cap while OPFS exceeds 24 MB", async () => {
  const pagePayload = JSON.stringify({
    has_more: true,
    records: [{ id: "m1", attributes: { kind: "message", created_at: "2026-11-01T00:00:00.000000Z" } }],
  });
  const fetchPage = async () => ({ status: 200, ok: true, text: async () => pagePayload });

  // OPFS mode: DB > 24 MB does NOT stop history fill.
  const opfsEnv = createTestEnvironment();
  opfsEnv.hostMetrics.simulatedDbSize = 40 * 1024 * 1024; // 40 MB
  const opfsTab = opfsEnv.spawnWorker({ fetchImpl: fetchPage });
  const opfsBoot = await opfsTab.rpc("boot", { module: {}, path: "/email?member=maya&inbox=support", scope: "s1" });
  assert.equal(opfsBoot.storageMode, "opfs");
  const opfsMore = await opfsTab.runtime.fillStep();
  assert.equal(opfsMore, true);
  assert.equal(opfsTab.runtime.fillState.full, false, "OPFS lifts the 24 MB history fill cap");
  assert.equal(opfsEnv.hostMetrics.databaseBytesCalls, 0, "OPFS fillStep reads O(1) size, never databaseBytes()");
  opfsTab.runtime.shutdown();

  // Safari Private Mode fallback: DB > 24 MB stops fill at the whole-file cap.
  const idbEnv = createTestEnvironment({ opfsUnavailable: true });
  idbEnv.hostMetrics.simulatedDbSize = 40 * 1024 * 1024;
  const idbTab = idbEnv.spawnWorker({ fetchImpl: fetchPage });
  const idbBoot = await idbTab.rpc("boot", { module: {}, path: "/email?member=maya&inbox=support", scope: "s1" });
  assert.equal(idbBoot.storageMode, "indexeddb");
  const idbMore = await idbTab.runtime.fillStep();
  assert.equal(idbMore, false);
  assert.equal(idbTab.runtime.fillState.full, true, "IndexedDB fallback keeps the 24 MB safety cap");
  idbTab.runtime.shutdown();
});

test("wipe closes OPFS handle and removes the database file cleanly", async () => {
  const env = createTestEnvironment();
  const tab = env.spawnWorker();
  await tab.rpc("boot", { module: {}, path: "/todo", scope: "s1" });
  assert.equal(env.openHandles.size, 1);

  const wiped = await tab.rpc("wipe");
  assert.deepEqual(wiped, { ok: true });
  assert.equal(env.openHandles.size, 0, "OPFS sync handle closed on wipe");
  assert.equal(env.opfsTree.get("instant-record-spinel").get("default").has("development.sqlite3"), false);
});

test("cold-boot IndexedDB deletion resets stale OPFS file cleanly on next boot", async () => {
  const env = createTestEnvironment();
  const tab1 = env.spawnWorker();
  await tab1.rpc("boot", { module: {}, path: "/todo", scope: "s1" });
  await tab1.rpc("request", { method: "POST", path: "/items", body: "before-wipe" });
  tab1.runtime.shutdown();

  // Simulate measure_controller.js deleting only IndexedDB and reloading cold.
  env.idbStores.get("__default__").clear();

  const tab2 = env.spawnWorker();
  const booted = await tab2.rpc("boot", { module: {}, path: "/todo", scope: "s1" });
  assert.equal(booted.restored, false, "stale OPFS without IDB metadata boots cold");
  const read = await tab2.rpc("request", { method: "GET", path: "/items" });
  assert.deepEqual(JSON.parse(read.body), []);
  tab2.runtime.shutdown();
});
