// Host for the compiled app (hand-written). Boots the WASI reactor wasm module ONCE per worker
// lifetime on an in-memory or OPFS-backed WASI filesystem, keeping the Spinel GC slab and SQLite
// connection live across requests and sync passes:
//   /storage   the app's SQLite file (and its secret key)
//   /host      in / out   request/sync input and output buffers
//              request    the gem writes "METHOD URL\nbody"
//              response   opening it makes the host perform that request, synchronously
//              notify     the gem writes "records_changed" when a sync pass moved rows,
//                         and the records it can list after it (changes.js)
//              events     the gem writes bridged ActiveSupport::Notifications JSON
// Works the same in Node (tests / replay) and in a browser worker; only `exchange` differs.
import { WASI, File, OpenFile, Directory, PreopenDirectory, ConsoleStdout } from "@bjorn3/browser_wasi_shim";
import { createAppHostClass } from "./app-host-core.js";

export { WasmFaultError } from "./faults.js";
export const AppHost = createAppHostClass({ WASI, File, OpenFile, Directory, PreopenDirectory, ConsoleStdout });
