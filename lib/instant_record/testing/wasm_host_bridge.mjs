// Persistent Node.js headless bridge for compiled app.wasm using AppHost
// (compiled/web/src/app-host.js). Speaks synchronous NDJSON over stdin/stdout
// so Ruby's FaultNetwork answers AppHost's synchronous `exchange(method, url, body)`
// callback inline with zero sockets and zero polling.
//
// Usage: node wasm_host_bridge.mjs <app-host.js path> <app.wasm path> [frontend/http.js path]
import fs from "node:fs";
import { pathToFileURL } from "node:url";

const [appHostPath, wasmPath, frontendHttpPath] = process.argv.slice(2);
if (!appHostPath || !wasmPath) {
  process.stderr.write("usage: node wasm_host_bridge.mjs <app-host.js> <app.wasm> [frontend/http.js]\n");
  process.exit(64);
}

const { AppHost } = await import(pathToFileURL(appHostPath).href);
const wasmModule = new WebAssembly.Module(fs.readFileSync(wasmPath));
const clients = new Map();

let readBuffer = Buffer.alloc(0);

function readLineSync() {
  const chunk = Buffer.alloc(16384);
  while (true) {
    const nl = readBuffer.indexOf(0x0a);
    if (nl !== -1) {
      const line = readBuffer.subarray(0, nl).toString("utf8");
      readBuffer = readBuffer.subarray(nl + 1);
      return line;
    }
    let bytesRead;
    try {
      bytesRead = fs.readSync(0, chunk, 0, chunk.length, null);
    } catch (err) {
      if (err.code === "EAGAIN" || err.code === "EINTR") continue;
      throw err;
    }
    if (bytesRead === 0) return null;
    readBuffer = Buffer.concat([readBuffer, chunk.subarray(0, bytesRead)]);
  }
}

function writeLineSync(obj) {
  const data = Buffer.from(JSON.stringify(obj) + "\n", "utf8");
  let offset = 0;
  while (offset < data.length) {
    try {
      offset += fs.writeSync(1, data, offset, data.length - offset);
    } catch (err) {
      if (err.code === "EAGAIN" || err.code === "EINTR") continue;
      throw err;
    }
  }
}

function syncExchange(clientId) {
  return (method, url, body) => {
    writeLineSync({ type: "exchange", client: clientId, method, url, body });
    const raw = readLineSync();
    if (raw === null) throw new Error("EOF waiting for exchange reply");
    const reply = JSON.parse(raw);
    return { status: Number(reply.status || 0), body: String(reply.body ?? "") };
  };
}

function getClient(id) {
  const host = clients.get(id);
  if (!host) throw new Error(`Unknown wasm client: ${id}`);
  return host;
}

// Verify frontend/http.js (`write` and `localHttpClient.request`) directly
// against a live AppHost instance via an injected fetch shim.
async function verifyFrontendHttp(clientId, httpFilePath) {
  const host = getClient(clientId);
  const rawSource = fs.readFileSync(httpFilePath, "utf8");
  // Inline a minimal HttpResponseError stub so frontend/http.js executes in
  // bare Node without requiring @inertiajs/core in WEB_NODE_MODULES.
  const stubbed = rawSource.replace(
    /import\s+\{\s*HttpResponseError\s*\}\s+from\s+["']@inertiajs\/core["'];?/,
    "class HttpResponseError extends Error { constructor(msg, response, url) { super(msg); this.response = response; this.url = url; } }"
  );
  const modUrl = "data:text/javascript;base64," + Buffer.from(stubbed, "utf8").toString("base64");
  const { write, localHttpClient } = await import(modUrl);

  const prevWindow = globalThis.window;
  const prevDocument = globalThis.document;
  const prevFetch = globalThis.fetch;
  const calls = [];
  const stderrLines = [];

  globalThis.window = { location: { href: "http://localhost/todo" } };
  globalThis.document = { cookie: "XSRF-TOKEN=test-csrf-token" };
  globalThis.fetch = async (input, init = {}) => {
    const parsed = new URL(String(input), "http://localhost");
    const method = (init.method || "GET").toUpperCase();
    const bodyText = init.body ? String(init.body) : "";
    const res = host.request(method, parsed.pathname + parsed.search, {
      body: bodyText,
      contentType: "application/x-www-form-urlencoded",
    });
    calls.push({ method, path: parsed.pathname + parsed.search, status: res.status, exit: res.exit });
    stderrLines.push(...res.errors);
    if (res.exit !== 0) {
      throw new Error(`wasm_request failed with exit=${res.exit}: ${res.errors.join("; ")}`);
    }
    const isRedirect = res.status >= 300 && res.status < 400;
    return {
      ok: res.status >= 200 && res.status < 300,
      status: res.status,
      type: isRedirect && init.redirect === "manual" ? "opaqueredirect" : "basic",
      text: async () => res.body,
    };
  };

  try {
    // 1. Exercise `write()` (frontend/http.js:40-49): form POST with 302 redirect.
    await write("/todo/issues", { "issue[title]": "frontend-http-write" });

    // 2. Exercise `localHttpClient.request()` GET + _inertia=1 + _only query params.
    const page = await localHttpClient.request({
      method: "GET",
      url: "/todo",
      params: {},
      headers: { "X-Inertia-Partial-Data": "issues" },
    });

    // 3. Exercise `localHttpClient.request()` POST write followed by page fetch.
    const indexRes = host.request("GET", "/todo");
    stderrLines.push(...indexRes.errors);

    return {
      ok: true,
      calls,
      pageStatus: page.status,
      containsWrittenTitle: indexRes.body.includes("frontend-http-write"),
      errors: stderrLines,
    };
  } finally {
    globalThis.window = prevWindow;
    globalThis.document = prevDocument;
    globalThis.fetch = prevFetch;
  }
}

writeLineSync({ type: "ready" });

while (true) {
  const line = readLineSync();
  if (line === null) break;
  if (!line.trim()) continue;

  try {
    const cmd = JSON.parse(line);
    switch (cmd.op) {
      case "create_client": {
        const host = new AppHost(wasmModule, {
          exchange: syncExchange(cmd.client),
          env: cmd.env || {},
        });
        host.ensureBooted();
        const bootErrors = host.errors.slice();
        clients.set(cmd.client, host);
        writeLineSync({ type: "result", ok: true, errors: bootErrors });
        break;
      }
      case "destroy_client": {
        clients.delete(cmd.client);
        writeLineSync({ type: "result", ok: true });
        break;
      }
      case "request": {
        const host = getClient(cmd.client);
        const res = host.request(cmd.method, cmd.path, {
          body: cmd.body ?? "",
          contentType: cmd.contentType || "application/x-www-form-urlencoded",
        });
        writeLineSync({ type: "result", ...res });
        break;
      }
      case "sync": {
        const host = getClient(cmd.client);
        const res = host.sync(cmd.endpoint || "");
        writeLineSync({ type: "result", ...res });
        break;
      }
      case "sync_plan": {
        const host = getClient(cmd.client);
        const plan = host.syncPlan();
        writeLineSync({ type: "result", plan, errors: host.errors.slice() });
        break;
      }
      case "consume_stream": {
        const host = getClient(cmd.client);
        const res = host.consumeStream(cmd.chunk ?? "");
        writeLineSync({ type: "result", ...res });
        break;
      }
      case "sync_state": {
        const host = getClient(cmd.client);
        const state = host.syncState();
        writeLineSync({ type: "result", ...state, errors: host.errors.slice() });
        break;
      }
      case "history": {
        const host = getClient(cmd.client);
        const res = host.history(cmd.key, cmd.response ?? "");
        writeLineSync({ type: "result", history: res, errors: host.errors.slice() });
        break;
      }
      case "database_bytes": {
        const host = getClient(cmd.client);
        const bytes = host.databaseBytes();
        const b64 = bytes ? Buffer.from(bytes).toString("base64") : "";
        writeLineSync({ type: "result", base64: b64 });
        break;
      }
      case "restore_database": {
        const host = getClient(cmd.client);
        const raw = Buffer.from(cmd.base64 || "", "base64");
        host.restoreDatabase(new Uint8Array(raw), cmd.schemaVersion || 0);
        writeLineSync({ type: "result", ok: true });
        break;
      }
      case "verify_frontend_http": {
        const res = await verifyFrontendHttp(cmd.client, cmd.httpPath || frontendHttpPath);
        writeLineSync({ type: "result", ...res });
        break;
      }
      case "shutdown": {
        writeLineSync({ type: "result", ok: true });
        process.exit(0);
      }
      default:
        writeLineSync({ type: "error", message: `Unknown op: ${cmd.op}` });
    }
  } catch (err) {
    writeLineSync({ type: "error", message: err?.stack || err?.message || String(err) });
  }
}
