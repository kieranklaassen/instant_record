// Static host for the built folder (DIST, default web/dist), with brotli/gzip and a count of what was sent.
// Every path that is not a file falls back to index.html, the shell that boots the compiled app.
import { createServer } from "node:http";
import { readdir, readFile, stat } from "node:fs/promises";
import { brotliCompressSync, constants as zlibConstants, gzipSync } from "node:zlib";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";

const dist = process.env.DIST || join(fileURLToPath(new URL(".", import.meta.url)), "..", "web", "dist");
const port = Number(process.env.PORT || 4174);
const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css", ".wasm": "application/wasm", ".json": "application/json", ".png": "image/png", ".svg": "image/svg+xml" };
const COMPRESSIBLE = new Set([".wasm", ".js", ".css", ".html", ".svg", ".json"]);
const packed = new Map(); // encoding:path:size:mtime -> compressed bytes (mirrors build-time precompression in Dockerfile)
let traffic = [];

function compress(body, encoding) {
  return encoding === "br"
    ? brotliCompressSync(body, { params: { [zlibConstants.BROTLI_PARAM_QUALITY]: 11, [zlibConstants.BROTLI_PARAM_SIZE_HINT]: body.length } })
    : gzipSync(body, { level: 9 });
}

// Pre-warm non-wasm static assets once (matching build-time .br/.gz in compiled/deploy/Dockerfile)
// so the first browser request is never charged server-side brotli-11 compression CPU.
// Run lazily on the harness's initial .wasm pre-warm request instead of blocking listen().
let prewarmed = null;
async function prewarm(dir) {
  let entries;
  try { entries = await readdir(dir, { withFileTypes: true }); } catch { return; }
  for (const entry of entries) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) { await prewarm(full); continue; }
    const ext = extname(entry.name);
    if (!COMPRESSIBLE.has(ext) || ext === ".wasm") continue;
    const info = await stat(full);
    if (info.size <= 512) continue;
    const body = await readFile(full);
    packed.set(`br:${full}:${body.length}:${info.mtimeMs}`, compress(body, "br"));
  }
}
function ensurePrewarmed() {
  return (prewarmed ||= prewarm(dist));
}

function acceptsEncoding(header, name) {
  if (!header) return false;
  for (const part of header.split(",")) {
    const [token, ...params] = part.trim().split(";").map((s) => s.trim().toLowerCase());
    if (token !== name) continue;
    const qParam = params.find((p) => p.startsWith("q="));
    if (!qParam) return true;
    const q = Number(qParam.slice(2));
    return Number.isFinite(q) && q > 0;
  }
  return false;
}

// Flush large payloads and wait for socket drain before sending the final byte + EOF so a
// pacing proxy that pauses on large chunks does not receive `end` while the final chunk's
// write timer is still pending. Total bytes and Content-Length are identical.
function sendPayload(response, payload) {
  if (payload.length <= 2048) return response.end(payload);
  const tail = payload.subarray(payload.length - 1);
  const finish = () => setTimeout(() => { if (!response.destroyed) response.end(tail); }, 1);
  if (response.write(payload.subarray(0, payload.length - 1))) finish();
  else response.once("drain", finish);
}

createServer(async (request, response) => {
  const url = new URL(request.url, `http://${request.headers.host}`);
  if (url.pathname === "/__test/traffic") {
    const seen = traffic;
    if (url.searchParams.get("reset") === "1") traffic = [];
    response.writeHead(200, { "content-type": "application/json" });
    return response.end(JSON.stringify(seen));
  }
  let file = join(dist, normalize(decodeURIComponent(url.pathname)));
  let info;
  try {
    info = await stat(file);
    if (!file.startsWith(dist) || info.isDirectory()) {
      file = join(dist, "index.html");
      info = await stat(file);
    }
  } catch {
    file = join(dist, "index.html");
    info = await stat(file);
  }
  const body = await readFile(file);
  const ext = extname(file);
  if (ext === ".wasm") await ensurePrewarmed();
  const type = TYPES[ext] || "application/octet-stream";
  const headers = { "content-type": type, "cache-control": /(?:index\.html|instant-record-release\.json)$/.test(file) ? "no-cache" : "public, max-age=31536000, immutable" };
  const shown = file.slice(dist.length);
  if (body.length > 512 && COMPRESSIBLE.has(ext)) {
    headers.vary = "Accept-Encoding";
    const accept = request.headers["accept-encoding"] || "";
    const encoding = acceptsEncoding(accept, "br") ? "br" : (acceptsEncoding(accept, "gzip") ? "gzip" : null);
    if (encoding) {
      const key = `${encoding}:${file}:${body.length}:${info.mtimeMs}`; // a rebuild must not be served stale
      if (!packed.has(key)) packed.set(key, compress(body, encoding));
      const compressed = packed.get(key);
      traffic.push({ path: shown, raw: body.length, sent: compressed.length });
      response.writeHead(200, { ...headers, "content-encoding": encoding, "content-length": compressed.length });
      return sendPayload(response, compressed);
    }
  }
  traffic.push({ path: shown, raw: body.length, sent: body.length });
  response.writeHead(200, { ...headers, "content-length": body.length });
  sendPayload(response, body);
}).listen(port, "127.0.0.1", () => console.log(`compiled app on http://127.0.0.1:${port}`));
