import { SyncOPFSFile, OpenSyncOPFSFile, wasi } from "@bjorn3/browser_wasi_shim";
import { createPagedSyncOPFSClasses } from "./opfs-wasi-core.js";

export const { PagedSyncOPFSFile, PagedOpenSyncOPFSFile } = createPagedSyncOPFSClasses({
  SyncOPFSFile,
  OpenSyncOPFSFile,
  wasi,
});
