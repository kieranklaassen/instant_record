// Static host for the built folder (DIST, default web/dist), with gzip and a count of what was sent.
// Every path that is not a file falls back to index.html, the shell that boots the compiled app.
import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { gzipSync } from "node:zlib";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";

const dist = process.env.DIST || join(fileURLToPath(new URL(".", import.meta.url)), "..", "web", "dist");
const port = Number(process.env.PORT || 4174);
const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css", ".wasm": "application/wasm", ".json": "application/json", ".png": "image/png", ".svg": "image/svg+xml" };
const packed = new Map(); // path -> gzip bytes (the wasm is large; compress it once)
let traffic = [];

createServer(async (request, response) => {
  const url = new URL(request.url, `http://${request.headers.host}`);
  if (url.pathname === "/__test/traffic") {
    const seen = traffic;
    if (url.searchParams.get("reset") === "1") traffic = [];
    response.writeHead(200, { "content-type": "application/json" });
    return response.end(JSON.stringify(seen));
  }
  let file = join(dist, normalize(decodeURIComponent(url.pathname)));
  try {
    if (!file.startsWith(dist) || (await stat(file)).isDirectory()) file = join(dist, "index.html");
  } catch {
    file = join(dist, "index.html");
  }
  const body = await readFile(file);
  const type = TYPES[extname(file)] || "application/octet-stream";
  const headers = { "content-type": type, "cache-control": /(?:index\.html|instant-record-release\.json)$/.test(file) ? "no-cache" : "public, max-age=31536000, immutable" };
  const shown = file.slice(dist.length);
  if (/gzip/.test(request.headers["accept-encoding"] || "") && body.length > 512 && type !== "image/png") {
    const key = file + ":" + body.length + ":" + (await stat(file)).mtimeMs; // a rebuild must not be served stale
    if (!packed.has(key)) packed.set(key, gzipSync(body));
    const gz = packed.get(key);
    traffic.push({ path: shown, raw: body.length, sent: gz.length });
    response.writeHead(200, { ...headers, "content-encoding": "gzip" });
    return response.end(gz);
  }
  traffic.push({ path: shown, raw: body.length, sent: body.length });
  response.writeHead(200, headers);
  response.end(body);
}).listen(port, "127.0.0.1", () => console.log(`compiled app on http://127.0.0.1:${port}`));
