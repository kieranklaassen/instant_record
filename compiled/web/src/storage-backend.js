// Storage backend for compiled browser workers:
//   - Primary: OPFS page-level FileSystemSyncAccessHandle wrapped in PagedSyncOPFSFile
//     so SQLite reads/writes 4 KB pages directly without whole-file serialization.
//   - Fallback: IndexedDB whole-file snapshots (e.g., Safari Private Mode or browsers
//     without FileSystemSyncAccessHandle).
//
// Small metadata (schema version, secret_key_base, migration history, schema digest,
// history fill edge, revision) stays in IndexedDB's v3 store so existing profiles
// upgrade in place and failed migrations roll back cleanly.

export const FILL_BUDGET_BYTES_IDB = 24 * 1024 * 1024;
export const FILL_BUDGET_BYTES_OPFS = Number.POSITIVE_INFINITY;
export const OPFS_ROOT_DIR = "instant-record-spinel";
export const OPFS_DB_FILENAME = "development.sqlite3";

const PERMANENT_UNAVAILABLE_ERRORS = new Set([
  "SecurityError",
  "NotAllowedError",
  "NotSupportedError",
  "TypeError",
]);

export function opfsDirectorySegments(scope) {
  if (!scope) return [OPFS_ROOT_DIR, "default"];
  const parts = String(scope)
    .split("/")
    .filter(Boolean)
    .map(part => part.replace(/[^a-zA-Z0-9._-]/g, "_"));
  return [OPFS_ROOT_DIR, "mail", ...parts];
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function ensureDirectory(root, segments) {
  let dir = root;
  for (const segment of segments) {
    dir = await dir.getDirectoryHandle(segment, { create: true });
  }
  return dir;
}

async function openSyncHandleWithRetry(fileHandle, { maxAttempts = 6, baseDelayMs = 25, delay = sleep } = {}) {
  let lastError;
  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    try {
      return await fileHandle.createSyncAccessHandle();
    } catch (error) {
      lastError = error;
      // Another worker's handle may still be releasing during rapid leader failover.
      if (error?.name !== "NoModificationAllowedError" || attempt === maxAttempts - 1) {
        throw error;
      }
      await delay(baseDelayMs * (2 ** attempt));
    }
  }
  throw lastError;
}

export function isPermanentOpfsError(error) {
  if (!error) return false;
  return PERMANENT_UNAVAILABLE_ERRORS.has(error.name);
}

// Open OPFS sync storage for `scope`, or return an IndexedDB fallback descriptor when
// OPFS sync handles are unavailable.
export async function openDatabaseStorage(scope, {
  storage = globalThis.navigator?.storage,
  createFile,
  maxAttempts = 6,
  baseDelayMs = 25,
  delay = sleep,
} = {}) {
  if (!storage || typeof storage.getDirectory !== "function") {
    return createIndexedDbBackend(scope, "opfs-unsupported");
  }
  try {
    const root = await storage.getDirectory();
    const segments = opfsDirectorySegments(scope);
    const dir = await ensureDirectory(root, segments);
    const fileHandle = await dir.getFileHandle(OPFS_DB_FILENAME, { create: true });
    if (typeof fileHandle.createSyncAccessHandle !== "function") {
      return createIndexedDbBackend(scope, "sync-access-handle-unsupported");
    }
    const syncHandle = await openSyncHandleWithRetry(fileHandle, { maxAttempts, baseDelayMs, delay });
    const file = createFile(syncHandle);

    let closed = false;
    return {
      mode: "opfs",
      fallbackReason: null,
      fillBudgetBytes: FILL_BUDGET_BYTES_OPFS,
      file,
      hasDatabase() {
        return !closed && file.byteLength() > 0;
      },
      databaseSize() {
        return closed ? 0 : file.byteLength();
      },
      readAllBytes() {
        return closed ? null : file.readAll();
      },
      writeAllBytes(bytes) {
        if (closed) throw new Error("OPFS storage is closed");
        file.writeAll(bytes);
      },
      truncate(size = 0) {
        if (closed) throw new Error("OPFS storage is closed");
        file.truncate(size);
      },
      flush() {
        if (!closed) file.flush();
      },
      close() {
        if (closed) return;
        closed = true;
        try { file.flush(); } catch {}
        try { file.close(); } catch {}
      },
      async wipe() {
        this.close();
        try {
          await dir.removeEntry(OPFS_DB_FILENAME);
        } catch {
          // Entry may already be removed.
        }
      },
    };
  } catch (error) {
    // Safari Private Mode, restricted iframes, or exhausted transient lock contention
    // degrade cleanly to whole-file IndexedDB snapshots.
    const reason = isPermanentOpfsError(error) ? error.name : (error?.name || "opfs-open-failed");
    return createIndexedDbBackend(scope, reason);
  }
}

function createIndexedDbBackend(scope, fallbackReason) {
  return {
    mode: "indexeddb",
    fallbackReason,
    fillBudgetBytes: FILL_BUDGET_BYTES_IDB,
    file: null,
    hasDatabase() {
      return false;
    },
    databaseSize() {
      return 0;
    },
    readAllBytes() {
      return null;
    },
    writeAllBytes() {},
    truncate() {},
    flush() {},
    close() {},
    async wipe() {},
  };
}
