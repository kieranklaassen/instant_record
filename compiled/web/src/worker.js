// Dedicated worker: elects a single leader per (origin, partition) via navigator.locks.
// The leader mounts OPFS page-level WASI storage (PagedSyncOPFSFile) at
// /storage/development.sqlite3 (with clean IndexedDB fallback), runs the single hot
// AppHost, outbox drain, visibility-aware SSE change stream, server-directed background
// history fill, fail-loud WASM fault telemetry with a circuit breaker, bridged Ruby
// notifications, and an opt-in rolling `.irtrace` flight recorder, and serves peer tabs
// over dedicated channels with crash-safe failover.
import { AppHost } from "./app-host.js";
import { PagedSyncOPFSFile } from "./opfs-wasi-file.js";
import { createWorkerRuntime } from "./reactor-runtime.js";
import { openSnapshot, withFiles } from "./snapshot-store.js";

const runtime = createWorkerRuntime({
  env: {
    VITE_MANIFEST: import.meta.env.VITE_MANIFEST,
    VITE_SYNC_ENDPOINT: import.meta.env.VITE_SYNC_ENDPOINT,
    VITE_MOUNT_PATH: import.meta.env.VITE_MOUNT_PATH,
    VITE_SCHEMA_VERSION: import.meta.env.VITE_SCHEMA_VERSION,
    VITE_SCHEMA_BASELINE: import.meta.env.VITE_SCHEMA_BASELINE,
    VITE_MIGRATION_HISTORY: import.meta.env.VITE_MIGRATION_HISTORY,
    VITE_SCHEMA_DIGEST: import.meta.env.VITE_SCHEMA_DIGEST,
    VITE_SHELL_FINGERPRINT: import.meta.env.VITE_SHELL_FINGERPRINT,
    VITE_SHELL_SNAPSHOT: import.meta.env.VITE_SHELL_SNAPSHOT,
    VITE_SOURCE_VERSION: import.meta.env.VITE_SOURCE_VERSION,
    VITE_WASM_URL: import.meta.env.VITE_WASM_URL,
    VITE_SYNC_PARTITIONS: import.meta.env.VITE_SYNC_PARTITIONS,
    VITE_TRACE_SCHEMA: import.meta.env.VITE_TRACE_SCHEMA,
  },
  AppHost,
  PagedSyncOPFSFile,
  openSnapshot,
  withFiles,
  postMessage: msg => self.postMessage(msg),
  origin: self.location.origin,
});

self.addEventListener("online", () => runtime.handleOnline());
self.addEventListener("offline", () => runtime.handleOffline());
self.onmessage = event => runtime.handleMessage(event);
