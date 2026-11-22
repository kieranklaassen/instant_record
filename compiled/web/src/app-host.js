// Host for the compiled app (hand-written). Boots the WASI reactor wasm module ONCE per worker
// lifetime on an in-memory WASI filesystem, keeping the Spinel GC slab and SQLite connection live
// across requests and sync passes:
//   /storage   the app's SQLite file (and its secret key)
//   /host      in / out   request/sync input and output buffers
//              request    the gem writes "METHOD URL\nbody"
//              response   opening it makes the host perform that request, synchronously
//              notify     the gem writes "records_changed" when a sync pass moved rows,
//                         and the records it can list after it (changes.js)
// Works the same in Node (tests) and in a browser worker; only `exchange` differs.
import { WASI, File, OpenFile, Directory, PreopenDirectory, ConsoleStdout } from "@bjorn3/browser_wasi_shim";
import { readNotice } from "./changes.js";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

class ResponseFile extends File {
  constructor(host) {
    super(new Uint8Array());
    this.host = host;
  }

  path_open(oflags, rights, fdFlags) {
    const reqFile = this.host.hostDir.contents.get("request") || this.host.requestFile;
    const text = decoder.decode(reqFile.data);
    const newline = text.indexOf("\n");
    const [method, url] = text.slice(0, newline).split(" ");
    let status = 0;
    let body = "";
    try {
      ({ status, body } = this.host.exchange(method, url, text.slice(newline + 1)));
    } catch {
      status = 0; // offline: the gem's transport raises Transport::Error and the outbox keeps the write
    }
    this.host.exchanges.push(`${method} ${url} -> ${status}`);
    this.data = encoder.encode(`${status}\n${body}`);
    return super.path_open(oflags, rights, fdFlags);
  }
}

export class AppHost {
  // exchange(method, url, body) -> { status, body }, synchronous.
  constructor(module, { exchange, env = {} }) {
    this.module = module;
    this.exchange = exchange;
    this.env = {
      SPINEL_GC_SLAB_MB: "8",
      DATABASE_POOL_SIZE: "1",
      RAILS_ENV: "production",
      SECRET_KEY_BASE: randomHex(64),
      ...env,
    };
    this.storage = new Directory(new Map());
    this.inFile = new File(new Uint8Array());
    this.outFile = new File(new Uint8Array());
    this.requestFile = new File(new Uint8Array());
    this.notifyFile = new File(new Uint8Array());
    this.hostDir = new Directory(new Map([
      ["in", this.inFile],
      ["out", this.outFile],
      ["request", this.requestFile],
      ["response", new ResponseFile(this)],
      ["notify", this.notifyFile],
    ]));
    this.root = new Map([
      ["storage", this.storage],
      ["tmp", new Directory(new Map())],
      ["host", this.hostDir],
    ]);
    this.cookies = new Map();
    this.exchanges = [];
    this.errors = [];
    this.instance = null;
  }

  // The SQLite file's bytes, for persisting between page loads (null before the first run).
  databaseBytes() {
    const file = this.storage.contents.get("development.sqlite3");
    return file ? file.data : null;
  }

  restoreDatabase(bytes, schemaVersion = 0) {
    this.storage.contents.set("development.sqlite3", new File(bytes));
    this.hostDir.contents.set("schema_version", new File(encoder.encode(String(schemaVersion).padStart(20, "0"))));
  }

  restoreForOutboxExtraction(bytes) {
    this.storage.contents.set("development.sqlite3", new File(bytes));
    this.hostDir.contents.set("recovery", new File(encoder.encode("extract_outbox")));
  }

  extractOutbox(bytes) {
    if (!bytes || !bytes.length) return [];
    this.restoreForOutboxExtraction(bytes);
    const result = this.call("wasm_export_outbox", new Uint8Array());
    if (result.exit !== 0) {
      throw new Error(result.errors.join("\n") || "Failed to extract outbox mutations");
    }
    const parsed = JSON.parse(decoder.decode(result.out) || "[]");
    return Array.isArray(parsed) ? parsed : [];
  }

  importOutbox(rows) {
    if (!Array.isArray(rows) || rows.length === 0) return { imported: 0 };
    const result = this.call("wasm_import_outbox", encoder.encode(JSON.stringify(rows)));
    if (result.exit !== 0) {
      throw new Error(result.errors.join("\n") || "Failed to import preserved outbox mutations");
    }
    return JSON.parse(decoder.decode(result.out) || '{"imported":0}');
  }

  // Lazily instantiate and boot the WASI reactor once (after restoreDatabase has placed any saved
  // SQLite file into /storage).
  ensureBooted() {
    if (this.instance) return;
    const fds = [
      new OpenFile(new File(new Uint8Array())),
      new OpenFile(new File(new Uint8Array())),
      ConsoleStdout.lineBuffered((line) => this.errors.push(line)),
      new PreopenDirectory("/", this.root),
    ];
    const wasi = new WASI(
      ["app"],
      Object.entries(this.env).map(([key, value]) => `${key}=${value}`),
      fds,
      { debug: false },
    );
    const imports = { ...wasi.wasiImport };
    for (const name of ["sock_accept", "sock_recv", "sock_send", "sock_shutdown"]) imports[name] = () => 58; // ENOTSUP
    const instance = new WebAssembly.Instance(this.module, { wasi_snapshot_preview1: imports });
    wasi.initialize(instance);
    try {
      instance.exports.wasm_boot();
    } catch (error) {
      throw new Error(this.errors.join("\n") || error.message, { cause: error });
    }
    this.instance = instance;
  }

  call(exportName, inputBytes) {
    this.errors = [];
    this.ensureBooted();
    this.inFile.data = inputBytes;
    this.hostDir.contents.set("in", this.inFile);
    this.outFile.data = new Uint8Array();
    this.hostDir.contents.set("out", this.outFile);
    let exit;
    try {
      exit = this.instance.exports[exportName]();
    } catch (error) {
      exit = `trap: ${error.message}`;
    }
    const outEntry = this.hostDir.contents.get("out") || this.outFile;
    return { exit, out: outEntry.data, errors: this.errors.slice() };
  }

  // One HTTP request through the app's own router and controllers.
  request(method, path, { body = "", contentType = "application/x-www-form-urlencoded" } = {}) {
    // Rails forms send PATCH and DELETE as POST plus a _method field. The socket server applies
    // that override while reading the request; the reactor entry skips that reader, so do it here.
    if (method === "POST" && contentType.startsWith("application/x-www-form-urlencoded")) {
      const text = typeof body === "string" ? body : decoder.decode(body);
      const override = new URLSearchParams(text).get("_method");
      if (override && /^(patch|put|delete)$/i.test(override)) method = override.toUpperCase();
    }
    const payload = typeof body === "string" ? encoder.encode(body) : body;
    const cookie = [...this.cookies].map(([name, value]) => `${name}=${value}`).join("; ");
    const head = `${method} ${path} HTTP/1.1\r\nHost: localhost\r\n` +
      (cookie ? `Cookie: ${cookie}\r\n` : "") +
      (payload.length ? `Content-Type: ${contentType}\r\nContent-Length: ${payload.length}\r\n` : "") + "\r\n";
    const input = new Uint8Array(head.length + payload.length);
    input.set(encoder.encode(head));
    input.set(payload, head.length);

    const result = this.call("wasm_request", input);
    const text = decoder.decode(result.out);
    const split = text.indexOf("\n\n");
    const lines = (split < 0 ? text : text.slice(0, split)).split("\n");
    const headers = [];
    for (const line of lines.slice(1)) {
      const colon = line.indexOf(": ");
      if (colon < 0) continue;
      const name = line.slice(0, colon);
      const value = line.slice(colon + 2);
      if (name.toLowerCase() === "set-cookie") {
        const pair = value.split(";")[0];
        const equals = pair.indexOf("=");
        if (/max-age=0/i.test(value)) this.cookies.delete(pair.slice(0, equals));
        else this.cookies.set(pair.slice(0, equals), pair.slice(equals + 1));
      } else {
        headers.push([name, value]);
      }
    }
    const status = Number(lines[0]) || 500;
    return { status, headers, body: split < 0 ? "" : text.slice(split + 2), exit: result.exit, errors: result.errors };
  }

  // One pass of the gem's own sync loop (InstantRecord::Client.sync_pass).
  syncPlan() {
    const result = this.call("wasm_sync_plan", new Uint8Array());
    if (result.exit !== 0) throw new Error(result.errors.join("\n") || "Failed to read the sync plan");
    return JSON.parse(decoder.decode(result.out));
  }

  sync(endpoint, exchange = this.exchange) {
    this.notifyFile.data = new Uint8Array();
    this.hostDir.contents.set("notify", this.notifyFile);
    this.exchanges = [];
    const previousExchange = this.exchange;
    let result;
    try {
      this.exchange = exchange;
      result = this.call("wasm_sync", encoder.encode(endpoint || ""));
    } finally {
      this.exchange = previousExchange;
    }
    const text = decoder.decode(result.out);
    const notifyEntry = this.hostDir.contents.get("notify") || this.notifyFile;
    return {
      changed: text.startsWith("changed"),
      pending: Number(/pending=(\d+)/.exec(text)?.[1] ?? -1),
      cursor: Number(/cursor=(\d+)/.exec(text)?.[1] ?? 0),
      ...readNotice(decoder.decode(notifyEntry.data)),
      exchanges: this.exchanges,
      exit: result.exit,
      errors: result.errors,
    };
  }

  // Feed an SSE batch fetched asynchronously by the worker into InstantRecord::Client.consume_stream.
  consumeStream(chunk) {
    this.notifyFile.data = new Uint8Array();
    this.hostDir.contents.set("notify", this.notifyFile);
    const result = this.call("wasm_stream", encoder.encode(chunk));
    const text = decoder.decode(result.out);
    const notifyEntry = this.hostDir.contents.get("notify") || this.notifyFile;
    return {
      applied: Number(/applied=(\d+)/.exec(text)?.[1] ?? 0),
      cursor: Number(/cursor=(\d+)/.exec(text)?.[1] ?? 0),
      bootstrapped: !text.includes("bootstrap=needed"),
      ...readNotice(decoder.decode(notifyEntry.data)),
      exit: result.exit,
      errors: result.errors,
    };
  }

  history(key, response = "") {
    const result = this.call("wasm_history", encoder.encode(JSON.stringify({ key, response })));
    if (result.exit !== 0) throw new Error(result.errors.join("\n") || String(result.exit));
    return JSON.parse(decoder.decode(result.out));
  }

  syncState() {
    const result = this.call("wasm_cursor", new Uint8Array());
    const text = decoder.decode(result.out);
    return {
      bootstrapped: text.includes("bootstrap=ready"),
      cursor: Number(/cursor=(\d+)/.exec(text)?.[1] ?? 0),
      pending: Number(/pending=(\d+)/.exec(text)?.[1] ?? 0),
      // The name the server gave whoever this browser synced as, when it tells people apart.
      identity: /identity=(\S+)/.exec(text)?.[1] ?? "",
    };
  }
}

function randomHex(bytes) {
  const buffer = new Uint8Array(bytes);
  crypto.getRandomValues(buffer);
  return [...buffer].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
