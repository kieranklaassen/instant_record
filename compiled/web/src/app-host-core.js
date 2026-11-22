// Core AppHost factory (zero external dependencies) so both the browser bundle
// (via @bjorn3/browser_wasi_shim in app-host.js) and Node replay/tests share
// the exact same WASI host, fault detection, notification bridge, and flight
// recorder integration.
import { readNotice } from "./changes.js";
import { WasmFaultError, buildFault, isTrapExit, readEvents } from "./faults.js";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export function createAppHostClass({ WASI, File, OpenFile, Directory, PreopenDirectory, ConsoleStdout }) {
  class ResponseFile extends File {
    constructor(host) {
      super(new Uint8Array());
      this.host = host;
    }

    path_open(oflags, rights, fdFlags) {
      const reqFile = this.host.hostDir.contents.get("request") || this.host.requestFile;
      const text = decoder.decode(reqFile.data);
      const newline = text.indexOf("\n");
      const firstLine = newline < 0 ? text : text.slice(0, newline);
      const requestBody = newline < 0 ? "" : text.slice(newline + 1);
      const [method, url] = firstLine.split(" ");
      let status = 0;
      let body = "";
      try {
        ({ status, body } = this.host.exchange(method, url, requestBody));
      } catch {
        status = 0; // offline: the gem's transport raises Transport::Error and the outbox keeps the write
      }
      this.host.exchanges.push(`${method} ${url} -> ${status}`);
      this.host.exchangeRecords.push({
        method,
        url,
        requestBody,
        status,
        responseBody: body == null ? "" : String(body),
      });
      this.data = encoder.encode(`${status}\n${body ?? ""}`);
      return super.path_open(oflags, rights, fdFlags);
    }
  }

  return class AppHost {
    // exchange(method, url, body) -> { status, body }, synchronous.
    constructor(module, { exchange, env = {}, onFault = null, onEvents = null, onSuccess = null, recorder = null, clock = () => Date.now() } = {}) {
      this.module = module;
      this.exchange = exchange;
      this.onFault = onFault;
      this.onEvents = onEvents;
      this.onSuccess = onSuccess;
      this.recorder = recorder;
      this.clock = clock;
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
      this.eventsFile = new File(new Uint8Array());
      this.hostDir = new Directory(new Map([
        ["in", this.inFile],
        ["out", this.outFile],
        ["request", this.requestFile],
        ["response", new ResponseFile(this)],
        ["notify", this.notifyFile],
        ["events", this.eventsFile],
      ]));
      this.root = new Map([
        ["storage", this.storage],
        ["tmp", new Directory(new Map())],
        ["host", this.hostDir],
      ]);
      this.cookies = new Map();
      this.exchanges = [];
      this.exchangeRecords = [];
      this.errors = [];
      this.schemaVersion = 0;
      this.instance = null;
      this.poisoned = false;
      this.lastFault = null;
    }

    // The SQLite file's bytes, for persisting between page loads (null before the first run).
    databaseBytes() {
      const file = this.storage.contents.get("development.sqlite3");
      return file ? file.data : null;
    }

    // Independent copy-on-write snapshot of the live SQLite bytes for staging branches.
    cloneDatabaseBytes() {
      const bytes = this.databaseBytes();
      return bytes ? new Uint8Array(bytes) : null;
    }

    restoreDatabase(bytes, schemaVersion = 0) {
      this.schemaVersion = Number(schemaVersion) || 0;
      this.storage.contents.set("development.sqlite3", new File(bytes instanceof Uint8Array ? bytes.slice() : new Uint8Array(bytes)));
      this.hostDir.contents.set("schema_version", new File(encoder.encode(String(this.schemaVersion).padStart(20, "0"))));
      if (this.recorder?.enabled) {
        this.recorder.captureCheckpoint(this.snapshotForRecorder());
      }
    }

    snapshotForRecorder() {
      return {
        dbBytes: this.databaseBytes(),
        schemaVersion: this.schemaVersion,
        env: this.env,
        cookies: this.cookies,
      };
    }

    // Lazily instantiate and boot the WASI reactor once (after restoreDatabase has placed any saved
    // SQLite file into /storage).
    ensureBooted() {
      if (this.instance) return;
      if (this.poisoned) {
        throw new WasmFaultError(
          this.lastFault ||
            buildFault({
              exportName: "wasm_boot",
              exit: "trap: instance poisoned",
              trapped: true,
              fatal: true,
              at: this.clock(),
            }),
        );
      }
      this.errors = [];
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
        this.poisoned = true;
        const fault = buildFault({
          exportName: "wasm_boot",
          exit: `trap: ${error?.message || String(error)}`,
          errors: this.errors.slice(),
          trapped: true,
          fatal: true,
          stack: error?.stack || null,
          at: this.clock(),
        });
        this.lastFault = fault;
        this.onFault?.(fault);
        throw new WasmFaultError(fault, { cause: error });
      }
      this.instance = instance;
    }

    call(exportName, inputBytes) {
      const payload = inputBytes instanceof Uint8Array ? inputBytes : new Uint8Array(inputBytes || 0);
      this.errors = [];
      this.exchangeRecords = [];
      this.eventsFile.data = new Uint8Array();
      this.hostDir.contents.set("events", this.eventsFile);

      if (this.poisoned) {
        const fault = buildFault({
          exportName,
          exit: "trap: instance poisoned after previous fatal trap",
          errors: this.lastFault?.errors || [],
          trapped: true,
          fatal: true,
          at: this.clock(),
        });
        this.lastFault = fault;
        this.onFault?.(fault);
        return { exit: fault.exit, out: new Uint8Array(), errors: fault.errors.slice(), events: [], trapped: true, fault };
      }

      this.ensureBooted();

      const preCallSnapshot = this.recorder?.enabled ? this.snapshotForRecorder() : null;

      this.inFile.data = payload;
      this.hostDir.contents.set("in", this.inFile);
      this.outFile.data = new Uint8Array();
      this.hostDir.contents.set("out", this.outFile);

      let exit;
      let trapped = false;
      let stack = null;
      try {
        exit = this.instance.exports[exportName]();
      } catch (error) {
        trapped = true;
        this.poisoned = true;
        exit = `trap: ${error?.message || String(error)}`;
        stack = error?.stack || null;
      }

      const outEntry = this.hostDir.contents.get("out") || this.outFile;
      const eventsEntry = this.hostDir.contents.get("events") || this.eventsFile;
      const events = readEvents(decoder.decode(eventsEntry.data));
      const errors = this.errors.slice();
      const fault = exit === 0
        ? null
        : buildFault({
            exportName,
            exit,
            errors,
            trapped: trapped || isTrapExit(exit),
            fatal: trapped || isTrapExit(exit),
            stack,
            at: this.clock(),
          });

      if (events.length > 0) this.onEvents?.(events, exportName);
      if (fault) {
        this.lastFault = fault;
        this.onFault?.(fault);
      } else {
        this.onSuccess?.(exportName);
      }

      const outcome = { exit, out: outEntry.data, errors, events, trapped: !!fault?.trapped, fault };
      if (this.recorder?.enabled) {
        this.recorder.recordStep({
          exportName,
          inputBytes: payload,
          exchanges: this.exchangeRecords,
          outcome,
          preCallSnapshot,
        });
      }
      return outcome;
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
      return {
        status,
        headers,
        body: split < 0 ? "" : text.slice(split + 2),
        exit: result.exit,
        errors: result.errors,
        events: result.events,
        fault: result.fault,
      };
    }

    // One pass of the gem's own sync loop (InstantRecord::Client.sync_pass).
    syncPlan() {
      const result = this.call("wasm_sync_plan", new Uint8Array());
      if (result.exit !== 0) {
        throw new WasmFaultError(
          result.fault || buildFault({ exportName: "wasm_sync_plan", exit: result.exit, errors: result.errors, at: this.clock() }),
        );
      }
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
        changed: result.exit === 0 && text.startsWith("changed"),
        pending: result.exit === 0 ? Number(/pending=(\d+)/.exec(text)?.[1] ?? -1) : -1,
        cursor: result.exit === 0 ? Number(/cursor=(\d+)/.exec(text)?.[1] ?? 0) : 0,
        ...readNotice(decoder.decode(notifyEntry.data)),
        exchanges: this.exchanges,
        exit: result.exit,
        errors: result.errors,
        events: result.events,
        fault: result.fault,
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
        applied: result.exit === 0 ? Number(/applied=(\d+)/.exec(text)?.[1] ?? 0) : 0,
        cursor: result.exit === 0 ? Number(/cursor=(\d+)/.exec(text)?.[1] ?? 0) : 0,
        bootstrapped: result.exit === 0 ? !text.includes("bootstrap=needed") : true,
        ...readNotice(decoder.decode(notifyEntry.data)),
        exit: result.exit,
        errors: result.errors,
        events: result.events,
        fault: result.fault,
      };
    }

    history(key, response = "") {
      const result = this.call("wasm_history", encoder.encode(JSON.stringify({ key, response })));
      if (result.exit !== 0) {
        throw new WasmFaultError(
          result.fault || buildFault({ exportName: "wasm_history", exit: result.exit, errors: result.errors, at: this.clock() }),
        );
      }
      return JSON.parse(decoder.decode(result.out));
    }

    // Extract OutboxMutations recorded after `excludeIds` on the active SQLite database.
    branchOutbox(excludeIds = []) {
      const result = this.call("wasm_branch_outbox", encoder.encode(JSON.stringify({ exclude_ids: excludeIds })));
      if (result.exit !== 0) {
        throw new WasmFaultError(
          result.fault || buildFault({ exportName: "wasm_branch_outbox", exit: result.exit, errors: result.errors, at: this.clock() }),
        );
      }
      return JSON.parse(decoder.decode(result.out));
    }

    // Safely replay extracted branch OutboxMutations onto the active (`main`) SQLite database.
    branchReplay(mutations, { conflict = "lww" } = {}) {
      this.notifyFile.data = new Uint8Array();
      this.hostDir.contents.set("notify", this.notifyFile);
      const result = this.call("wasm_branch_replay", encoder.encode(JSON.stringify({ mutations, conflict })));
      if (result.exit !== 0) {
        throw new WasmFaultError(
          result.fault || buildFault({ exportName: "wasm_branch_replay", exit: result.exit, errors: result.errors, at: this.clock() }),
        );
      }
      const parsed = JSON.parse(decoder.decode(result.out));
      const notifyEntry = this.hostDir.contents.get("notify") || this.notifyFile;
      return {
        ...parsed,
        ...readNotice(decoder.decode(notifyEntry.data)),
        exit: result.exit,
        errors: result.errors,
        events: result.events,
        fault: result.fault,
      };
    }

    syncState() {
      const result = this.call("wasm_cursor", new Uint8Array());
      const text = decoder.decode(result.out);
      return {
        bootstrapped: result.exit === 0 && text.includes("bootstrap=ready"),
        cursor: result.exit === 0 ? Number(/cursor=(\d+)/.exec(text)?.[1] ?? 0) : 0,
        pending: result.exit === 0 ? Number(/pending=(\d+)/.exec(text)?.[1] ?? 0) : -1,
        // The name the server gave whoever this browser synced as, when it tells people apart.
        identity: result.exit === 0 ? (/identity=(\S+)/.exec(text)?.[1] ?? "") : "",
        exit: result.exit,
        errors: result.errors,
        events: result.events,
        fault: result.fault,
      };
    }
  };
}

function randomHex(bytes) {
  const buffer = new Uint8Array(bytes);
  if (globalThis.crypto?.getRandomValues) {
    globalThis.crypto.getRandomValues(buffer);
  } else {
    for (let i = 0; i < buffer.length; i++) buffer[i] = Math.floor(Math.random() * 256);
  }
  return [...buffer].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
