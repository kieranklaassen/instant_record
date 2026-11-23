// Shared HTTP request header utilities for the browser main thread, worker, and WASI AppHost.
const encoder = new TextEncoder();
const decoder = new TextDecoder();
const VALID_HEADER_NAME = /^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/;

export function normalizeHeaders(headers) {
  if (!headers) return [];
  if (typeof Headers !== "undefined" && headers instanceof Headers) return [...headers.entries()];
  if (Array.isArray(headers)) return headers;
  return Object.entries(headers);
}

export function extractHeaders(headers) {
  const out = {};
  for (const [key, value] of normalizeHeaders(headers)) {
    if (value !== undefined && value !== null) out[String(key)] = String(value);
  }
  return out;
}

export function hasHeader(headers, target) {
  const lower = target.toLowerCase();
  return Object.keys(headers || {}).some((key) => key.toLowerCase() === lower);
}

export function headerValue(headers, target) {
  if (!headers) return undefined;
  if (typeof Headers !== "undefined" && headers instanceof Headers) return headers.get(target) || undefined;
  const lower = target.toLowerCase();
  for (const [key, value] of normalizeHeaders(headers)) {
    if (String(key).toLowerCase() === lower) return value;
  }
  return undefined;
}

export function redirectHeaders(headers) {
  const forwarded = {};
  for (const [name, value] of normalizeHeaders(headers)) {
    if (value === undefined || value === null) continue;
    const lower = String(name).toLowerCase();
    if (lower === "content-type" || lower === "content-length") continue;
    forwarded[String(name)] = String(value);
  }
  return forwarded;
}

// Serialize a single HTTP/1.1 request for Tep::Parser.parse in the WASI reactor.
export function buildHttpRequest(method, path, { body = "", contentType, headers = {}, cookies = new Map() } = {}) {
  const entries = new Map();
  let headerHost = "";
  let headerContentType = "";
  let headerCookie = "";

  for (const [rawName, rawValue] of normalizeHeaders(headers)) {
    if (rawValue === undefined || rawValue === null) continue;
    const name = String(rawName).trim();
    if (!VALID_HEADER_NAME.test(name)) continue;
    const value = String(rawValue).replace(/[\r\n]+/g, " ").trim();
    const lower = name.toLowerCase();
    if (lower === "content-length") continue;
    if (lower === "host") {
      if (value) headerHost = value;
      continue;
    }
    if (lower === "content-type") {
      if (value) headerContentType = value;
      continue;
    }
    if (lower === "cookie") {
      if (value) headerCookie = value;
      continue;
    }
    entries.set(lower, [name, value]);
  }

  const effectiveContentType = contentType || headerContentType || "application/x-www-form-urlencoded";
  let verb = method;
  // Rails forms send PATCH and DELETE as POST plus a _method field. The socket server applies
  // that override while reading the request; the reactor entry skips that reader, so do it here.
  if (verb === "POST" && effectiveContentType.startsWith("application/x-www-form-urlencoded")) {
    const text = typeof body === "string" ? body : decoder.decode(body);
    const override = new URLSearchParams(text).get("_method");
    if (override && /^(patch|put|delete)$/i.test(override)) verb = override.toUpperCase();
  }

  const payload = typeof body === "string" ? encoder.encode(body) : body;
  const jarCookie = [...cookies].map(([name, value]) => `${name}=${value}`).join("; ");
  const cookie = jarCookie || headerCookie;
  let head = `${verb} ${path} HTTP/1.1\r\nHost: ${headerHost || "localhost"}\r\n`;
  if (cookie) head += `Cookie: ${cookie}\r\n`;
  for (const [, [name, value]] of entries) head += `${name}: ${value}\r\n`;
  if (payload.length) head += `Content-Type: ${effectiveContentType}\r\nContent-Length: ${payload.length}\r\n`;
  head += "\r\n";

  const headBytes = encoder.encode(head);
  const input = new Uint8Array(headBytes.length + payload.length);
  input.set(headBytes);
  input.set(payload, headBytes.length);
  return input;
}
