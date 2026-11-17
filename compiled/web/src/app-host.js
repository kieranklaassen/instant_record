// Host for the compiled app (hand-written). Runs the wasm module once per request or per sync
// pass on an in-memory WASI filesystem that outlives the runs:
//   /storage   the app's SQLite file (and its secret key)
//   /host      the seam the vendored gem's transport and notifier talk through:
//                request   the gem writes "METHOD URL\nbody"
//                response  opening it makes the host perform that request, synchronously
//                notify    the gem writes "records_changed" when a sync pass moved rows
// Works the same in Node (tests) and in a browser worker; only `exchange` differs.
import { WASI, File, OpenFile, Directory, PreopenDirectory, ConsoleStdout } from "@bjorn3/browser_wasi_shim";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

class ResponseFile extends File {
  constructor(host) {
    super(new Uint8Array());
    this.host = host;
  }

  path_open(oflags, rights, fdFlags) {
    const text = decoder.decode(this.host.requestFile.data);
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
    this.env = { SPINEL_GC_SLAB_MB: "8", RAILS_ENV: "production", SECRET_KEY_BASE: randomHex(64), ...env };
    this.storage = new Directory(new Map());
    this.requestFile = new File(new Uint8Array());
    this.notifyFile = new File(new Uint8Array());
    this.root = new Map([
      ["storage", this.storage],
      ["tmp", new Directory(new Map())],
      ["host", new Directory(new Map([["request", this.requestFile], ["response", new ResponseFile(this)], ["notify", this.notifyFile]]))],
    ]);
    this.cookies = new Map();
    this.exchanges = [];
  }

  // The SQLite file's bytes, for persisting between page loads (null before the first run).
  databaseBytes() {
    const file = this.storage.contents.get("development.sqlite3");
    return file ? file.data : null;
  }

  restoreDatabase(bytes) {
    this.storage.contents.set("development.sqlite3", new File(bytes));
  }

  run(env, stdinBytes) {
    const out = new File(new Uint8Array());
    const errors = [];
    const fds = [
      new OpenFile(new File(stdinBytes)),
      new OpenFile(out),
      ConsoleStdout.lineBuffered((line) => errors.push(line)),
      new PreopenDirectory("/", this.root),
    ];
    const wasi = new WASI(["app"], Object.entries({ ...this.env, ...env }).map(([key, value]) => `${key}=${value}`), fds, { debug: false });
    // The shim throws on socket calls; WASI preview 1 hosts answer "not supported" instead, which
    // is what the compiled runtime expects when it probes at startup.
    const imports = { ...wasi.wasiImport };
    for (const name of ["sock_accept", "sock_recv", "sock_send", "sock_shutdown"]) imports[name] = () => 58; // ENOTSUP
    const instance = new WebAssembly.Instance(this.module, { wasi_snapshot_preview1: imports });
    let exit;
    try {
      exit = wasi.start(instance);
    } catch (error) {
      exit = `trap: ${error.message}`;
    }
    return { exit, out: out.data, errors };
  }

  // One HTTP request through the app's own router and controllers.
  request(method, path, { body = "", contentType = "application/x-www-form-urlencoded" } = {}) {
    // Rails forms send PATCH and DELETE as POST plus a _method field. The socket server applies
    // that override while reading the request; the one-shot entry skips that reader, so do it here.
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
    const stdin = new Uint8Array(head.length + payload.length);
    stdin.set(encoder.encode(head));
    stdin.set(payload, head.length);

    const result = this.run({ WASM_MODE: "request" }, stdin);
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
  sync(endpoint) {
    this.notifyFile.data = new Uint8Array();
    this.exchanges = [];
    const result = this.run({ WASM_MODE: "sync", SYNC_ENDPOINT: endpoint }, new Uint8Array());
    const text = decoder.decode(result.out);
    return {
      changed: text.startsWith("changed"),
      pending: Number(/pending=(\d+)/.exec(text)?.[1] ?? -1),
      notified: decoder.decode(this.notifyFile.data) === "records_changed",
      exchanges: this.exchanges,
      exit: result.exit,
      errors: result.errors,
    };
  }
}

function randomHex(bytes) {
  const buffer = new Uint8Array(bytes);
  crypto.getRandomValues(buffer);
  return [...buffer].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
