// Dedicated worker: elects a single leader per (origin, scope) via navigator.locks.
// The leader mounts OPFS page-level WASI storage (PagedSyncOPFSFile) at
// /storage/development.sqlite3 (with clean IndexedDB fallback), runs the single hot
// AppHost, outbox drain, change polling, and background history fill, and serves
// peer tabs over dedicated channels with crash-safe failover.
import { AppHost } from "./app-host.js";
import { PagedSyncOPFSFile } from "./opfs-wasi-file.js";
import { createWorkerRuntime } from "./reactor-runtime.js";
import { openSnapshot, withFiles } from "./snapshot-store.js";

const runtime = createWorkerRuntime({
  env: {
    VITE_SYNC_ENDPOINT: import.meta.env.VITE_SYNC_ENDPOINT,
    VITE_SCHEMA_VERSION: import.meta.env.VITE_SCHEMA_VERSION,
    VITE_SCHEMA_BASELINE: import.meta.env.VITE_SCHEMA_BASELINE,
    VITE_MIGRATION_HISTORY: import.meta.env.VITE_MIGRATION_HISTORY,
    VITE_SCHEMA_DIGEST: import.meta.env.VITE_SCHEMA_DIGEST,
    VITE_SHELL_FINGERPRINT: import.meta.env.VITE_SHELL_FINGERPRINT,
    VITE_SHELL_SNAPSHOT: import.meta.env.VITE_SHELL_SNAPSHOT,
    VITE_SOURCE_VERSION: import.meta.env.VITE_SOURCE_VERSION,
    VITE_WASM_URL: import.meta.env.VITE_WASM_URL,
    VITE_SHARED_INBOX_DEMO: import.meta.env.VITE_SHARED_INBOX_DEMO,
  },
  AppHost,
  PagedSyncOPFSFile,
  openSnapshot,
  withFiles,
  postMessage: msg => self.postMessage(msg),
  origin: self.location.origin,
});

self.addEventListener("online", () => runtime.handleOnline());
self.onmessage = event => runtime.handleMessage(event);
