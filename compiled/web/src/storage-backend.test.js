import assert from "node:assert/strict";
import { test } from "node:test";
import {
  FILL_BUDGET_BYTES_IDB,
  FILL_BUDGET_BYTES_OPFS,
  openDatabaseStorage,
  opfsDirectorySegments,
} from "./storage-backend.js";

function createFakeOpfs({ failAttempts = 0, failError = null, omitCreateSync = false } = {}) {
  const tree = new Map();
  let attempts = 0;

  function makeSyncHandle(entry) {
    return {
      closed: false,
      flushes: 0,
      getSize() { return entry.bytes.byteLength; },
      read(buf, { at = 0 } = {}) {
        const target = new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
        if (at >= entry.bytes.byteLength) return 0;
        const slice = entry.bytes.subarray(at, at + target.byteLength);
        target.set(slice);
        return slice.byteLength;
      },
      write(buf, { at = 0 } = {}) {
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
      flush() { this.flushes++; },
      close() { this.closed = true; },
    };
  }

  function makeDir(map) {
    return {
      async getDirectoryHandle(name, { create = false } = {}) {
        if (!map.has(name)) {
          if (!create) throw Object.assign(new Error("NotFound"), { name: "NotFoundError" });
          map.set(name, new Map());
        }
        return makeDir(map.get(name));
      },
      async getFileHandle(name, { create = false } = {}) {
        if (!map.has(name)) {
          if (!create) throw Object.assign(new Error("NotFound"), { name: "NotFoundError" });
          map.set(name, { bytes: new Uint8Array(0) });
        }
        const entry = map.get(name);
        if (omitCreateSync) return {};
        return {
          async createSyncAccessHandle() {
            attempts++;
            if (failError && attempts <= failAttempts) throw failError;
            return makeSyncHandle(entry);
          },
        };
      },
      async removeEntry(name) {
        map.delete(name);
      },
    };
  }

  return {
    tree,
    get attempts() { return attempts; },
    storage: {
      async getDirectory() {
        return makeDir(tree);
      },
    },
  };
}

function fakeCreateFile(handle) {
  return {
    handle,
    byteLength: () => handle.getSize(),
    readAll: () => {
      const buf = new Uint8Array(handle.getSize());
      handle.read(buf, { at: 0 });
      return buf;
    },
    writeAll: bytes => {
      handle.truncate(0);
      if (bytes.byteLength) handle.write(bytes, { at: 0 });
      handle.flush();
    },
    truncate: size => { handle.truncate(size); handle.flush(); },
    flush: () => handle.flush(),
    close: () => handle.close(),
  };
}

test("opfsDirectorySegments isolates default and scoped mailbox databases", () => {
  assert.deepEqual(opfsDirectorySegments(""), ["instant-record-spinel", "default"]);
  assert.deepEqual(opfsDirectorySegments("maya/support"), ["instant-record-spinel", "mail", "maya", "support"]);
});

test("openDatabaseStorage mounts OPFS with unbounded history fill budget and supports wipe", async () => {
  const opfs = createFakeOpfs();
  const backend = await openDatabaseStorage("maya/support", {
    storage: opfs.storage,
    createFile: fakeCreateFile,
  });

  assert.equal(backend.mode, "opfs");
  assert.equal(backend.fillBudgetBytes, FILL_BUDGET_BYTES_OPFS);
  assert.equal(backend.hasDatabase(), false);

  backend.writeAllBytes(new Uint8Array([1, 2, 3, 4]));
  assert.equal(backend.hasDatabase(), true);
  assert.equal(backend.databaseSize(), 4);
  assert.deepEqual(backend.readAllBytes(), new Uint8Array([1, 2, 3, 4]));

  await backend.wipe();
  assert.equal(backend.hasDatabase(), false);
  assert.equal(opfs.tree.get("instant-record-spinel").get("mail").get("maya").get("support").has("development.sqlite3"), false);
});

test("openDatabaseStorage retries transient NoModificationAllowedError during leader failover", async () => {
  const opfs = createFakeOpfs({
    failAttempts: 2,
    failError: Object.assign(new Error("handle still closing"), { name: "NoModificationAllowedError" }),
  });
  const sleeps = [];
  const backend = await openDatabaseStorage("", {
    storage: opfs.storage,
    createFile: fakeCreateFile,
    delay: async ms => { sleeps.push(ms); },
    baseDelayMs: 10,
  });

  assert.equal(backend.mode, "opfs");
  assert.equal(opfs.attempts, 3);
  assert.deepEqual(sleeps, [10, 20]);
  backend.close();
});

test("openDatabaseStorage falls back cleanly to IndexedDB in Safari Private Mode or unsupported browsers", async () => {
  const securityErr = Object.assign(new Error("Private mode"), { name: "SecurityError" });
  const opfsPrivate = createFakeOpfs({ failAttempts: 10, failError: securityErr });
  const privateFallback = await openDatabaseStorage("", {
    storage: opfsPrivate.storage,
    createFile: fakeCreateFile,
  });
  assert.equal(privateFallback.mode, "indexeddb");
  assert.equal(privateFallback.fallbackReason, "SecurityError");
  assert.equal(privateFallback.fillBudgetBytes, FILL_BUDGET_BYTES_IDB);
  assert.equal(opfsPrivate.attempts, 1, "permanent errors do not retry");

  const noSync = createFakeOpfs({ omitCreateSync: true });
  const unsupportedFallback = await openDatabaseStorage("", {
    storage: noSync.storage,
    createFile: fakeCreateFile,
  });
  assert.equal(unsupportedFallback.mode, "indexeddb");
  assert.equal(unsupportedFallback.fallbackReason, "sync-access-handle-unsupported");

  const missingStorage = await openDatabaseStorage("", { storage: undefined, createFile: fakeCreateFile });
  assert.equal(missingStorage.mode, "indexeddb");
  assert.equal(missingStorage.fallbackReason, "opfs-unsupported");
});
