// Schema-aware PII redaction with deterministic per-trace pseudonymization.
// Preserves structural columns (PKs, FKs, timestamps, sync bookkeeping) and
// value equality within a trace so replayed bugs keep their exact control flow
// without leaking emails, credentials, cookies, or personal text.
import { sha256Hex } from "./sha256.js";

const decoder = new TextDecoder();

export const STRUCTURAL_SAFE_COLUMNS = new Set([
  "id",
  "created_at",
  "updated_at",
  "deleted_at",
  "server_version",
  "sync_state",
  "cursor",
  "operation",
  "record_type",
  "record_id",
  "mutation_id",
  "base_version",
  "status",
  "kind",
  "type",
  "version",
  "has_more",
  "position",
  "done",
  "completed",
  "archived",
  "unread",
  "starred",
  "read_at",
  "sent_at",
  "published_at",
  "role",
  "state",
]);

export const DEFAULT_PII_PATTERNS = [
  /(^|_)e?mail(_|$|s$|_address$)/i,
  /(^|_)(phone|mobile|tel|telephone|fax)(_|$)/i,
  /(^|_)(password|passwd|pwd|secret|token|api_key|access_key|private_key|auth|credential|bearer)(_|$)/i,
  /(^|_)(ssn|social_security|tax_id|passport|license_number|national_id)(_|$)/i,
  /(^|_)(credit_card|card_number|cvv|cvc|iban|routing_number|account_number)(_|$)/i,
  /(^|_)(address|street|city|zip|postal|postcode)(_|$)/i,
  /(^|_)(ip|ip_address|user_agent)(_|$)/i,
  /(^|_)(cookie|session|csrf)(_|$)/i,
  /(^|_)(first_name|last_name|full_name|real_name|display_name|username|dob|birth_?date)(_|$)/i,
  /(^|_)(from_address|to_address|cc|bcc|reply_to|sender|recipient|from_email|to_email|author_email)(_|$)/i,
  /^identity$/i,
];

const SENSITIVE_HEADER_RE = /^(cookie|set-cookie|authorization|proxy-authorization|x-csrf-token|x-api-key|x-auth-token)$/i;
const SENSITIVE_QUERY_PARAM_RE = /(scope|identity|token|secret|key|password|passwd|email|auth|session|sig|signature)/i;
const SENSITIVE_ENV_RE = /(secret|token|key|password|passwd|auth|cookie|credential)/i;
const EMAIL_VALUE_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export function modelNameToTableName(modelName) {
  if (!modelName) return "";
  const base = String(modelName).split("::").pop();
  const snake = base
    .replace(/([A-Z]+)([A-Z][a-z])/g, "$1_$2")
    .replace(/([a-z\d])([A-Z])/g, "$1_$2")
    .toLowerCase();
  if (snake.endsWith("y") && !/[aeiou]y$/.test(snake)) return snake.slice(0, -1) + "ies";
  if (/(s|x|z|ch|sh)$/.test(snake)) return snake + "es";
  return snake + "s";
}

function normalizeSchema(schema) {
  const normalized = {};
  if (!schema || typeof schema !== "object") return normalized;
  for (const [table, cols] of Object.entries(schema)) {
    if (Array.isArray(cols)) {
      normalized[table.toLowerCase()] = cols.map((col) =>
        typeof col === "string" ? { name: col, type: "string" } : { name: String(col.name), type: String(col.type || "string") },
      );
    } else if (cols && typeof cols === "object") {
      normalized[table.toLowerCase()] = Object.entries(cols).map(([name, type]) => ({ name, type: String(type || "string") }));
    }
  }
  return normalized;
}

export class Redactor {
  constructor({ schema = {}, piiColumns = {}, safeColumns = {}, salt = null } = {}) {
    this.schema = normalizeSchema(schema);
    this.explicitPii = new Map();
    this.explicitSafe = new Map();
    for (const [table, cols] of Object.entries(piiColumns || {})) {
      this.explicitPii.set(table.toLowerCase(), new Set(Array.from(cols, (c) => String(c).toLowerCase())));
    }
    for (const [table, cols] of Object.entries(safeColumns || {})) {
      this.explicitSafe.set(table.toLowerCase(), new Set(Array.from(cols, (c) => String(c).toLowerCase())));
    }
    this.salt = salt || randomSalt();
    this.redactedFields = new Set();
    this.redactedColumns = {};
  }

  isPiiColumn(tableOrModel, columnName) {
    const col = String(columnName || "").toLowerCase();
    if (!col) return false;
    const table = this.resolveTableName(tableOrModel);
    if (this.explicitSafe.get(table)?.has(col) || this.explicitSafe.get("*")?.has(col)) return false;
    if (this.explicitPii.get(table)?.has(col) || this.explicitPii.get("*")?.has(col)) return true;
    if (STRUCTURAL_SAFE_COLUMNS.has(col) || col.endsWith("_id") || col.endsWith("_at")) return false;
    return DEFAULT_PII_PATTERNS.some((pattern) => pattern.test(col));
  }

  resolveTableName(tableOrModel) {
    if (!tableOrModel) return "*";
    const lower = String(tableOrModel).toLowerCase();
    if (this.schema[lower] || this.explicitPii.has(lower) || this.explicitSafe.has(lower)) return lower;
    const guessed = modelNameToTableName(tableOrModel);
    if (this.schema[guessed] || this.explicitPii.has(guessed) || this.explicitSafe.has(guessed)) return guessed;
    return guessed || lower;
  }

  schemaPiiMap(extraSchema = null) {
    const merged = { ...this.schema, ...normalizeSchema(extraSchema) };
    const result = {};
    for (const [table, columns] of Object.entries(merged)) {
      if (table === "schema_migrations" || table === "ar_internal_metadata" || table === "instant_record_sync_metadata") continue;
      const sensitive = columns
        .map((c) => c.name)
        .filter((col) => this.isPiiColumn(table, col));
      if (sensitive.length > 0) result[table] = sensitive;
    }
    for (const [table, cols] of this.explicitPii.entries()) {
      if (table === "*") continue;
      const existing = new Set(result[table] || []);
      for (const col of cols) existing.add(col);
      if (existing.size > 0) result[table] = [...existing];
    }
    return result;
  }

  hasSchemaPii(extraSchema = null) {
    return Object.keys(this.schemaPiiMap(extraSchema)).length > 0;
  }

  pseudonymize(value, hint = "") {
    if (value === null || value === undefined || value === "") return value;
    const text = String(value);
    const hash = sha256Hex(`${this.salt}:${hint}:${text}`).slice(0, 12);
    const lowerHint = String(hint).toLowerCase();
    if (lowerHint.includes("email") || EMAIL_VALUE_RE.test(text)) {
      return `redacted-${hash}@redacted.invalid`;
    }
    if (lowerHint.includes("phone") || lowerHint.includes("tel") || lowerHint.includes("mobile")) {
      return `+1-555-${hash.slice(0, 4)}`;
    }
    return `[redacted:${hash}]`;
  }

  noteRedactedColumn(table, column) {
    const key = table || "*";
    if (!this.redactedColumns[key]) this.redactedColumns[key] = [];
    if (!this.redactedColumns[key].includes(column)) this.redactedColumns[key].push(column);
    this.redactedFields.add(column);
  }

  redactValueForField(tableOrModel, fieldName, value) {
    if (value === null || value === undefined) return value;
    const table = this.resolveTableName(tableOrModel);
    if (this.isPiiColumn(table, fieldName)) {
      this.noteRedactedColumn(table, fieldName);
      if (typeof value === "string" || typeof value === "number") {
        return this.pseudonymize(value, fieldName);
      }
      if (Array.isArray(value)) {
        return value.map((item) => this.pseudonymize(item, fieldName));
      }
      if (typeof value === "object") {
        return this.pseudonymize(JSON.stringify(value), fieldName);
      }
      return this.pseudonymize(value, fieldName);
    }
    if (typeof value === "string" && EMAIL_VALUE_RE.test(value.trim())) {
      this.redactedFields.add(fieldName);
      return this.pseudonymize(value.trim(), "email");
    }
    if (Array.isArray(value)) {
      return value.map((item) => (item && typeof item === "object" ? this.redactObject(table, item) : item));
    }
    if (value && typeof value === "object") {
      return this.redactObject(table, value);
    }
    return value;
  }

  redactObject(tableOrModel, obj) {
    if (!obj || typeof obj !== "object" || Array.isArray(obj)) return obj;
    const out = {};
    for (const [key, value] of Object.entries(obj)) {
      out[key] = this.redactValueForField(tableOrModel, key, value);
    }
    return out;
  }

  redactRecordAttributes(recordType, attributes) {
    if (!attributes || typeof attributes !== "object") return attributes;
    return this.redactObject(recordType, attributes);
  }

  redactEnv(env) {
    const out = {};
    for (const [key, value] of Object.entries(env || {})) {
      if (SENSITIVE_ENV_RE.test(key)) {
        this.redactedFields.add(key.toLowerCase());
        out[key] = this.pseudonymize(value, key);
      } else {
        out[key] = value;
      }
    }
    return out;
  }

  redactCookies(cookies) {
    const out = {};
    const entries = cookies instanceof Map ? [...cookies.entries()] : Object.entries(cookies || {});
    for (const [name, value] of entries) {
      this.redactedFields.add("cookie");
      out[name] = this.pseudonymize(value, `cookie:${name}`);
    }
    return out;
  }

  redactUrl(urlString) {
    if (!urlString || !urlString.includes("?")) return urlString;
    const q = urlString.indexOf("?");
    const base = urlString.slice(0, q);
    const params = new URLSearchParams(urlString.slice(q + 1));
    let changed = false;
    for (const [key, value] of [...params.entries()]) {
      if (SENSITIVE_QUERY_PARAM_RE.test(key) || this.isPiiColumn("*", key)) {
        this.redactedFields.add(key.toLowerCase());
        params.set(key, this.pseudonymize(value, key));
        changed = true;
      }
    }
    return changed ? `${base}?${params.toString()}` : urlString;
  }

  redactFormBody(body) {
    if (!body) return body;
    const params = new URLSearchParams(body);
    let changed = false;
    for (const [key, value] of [...params.entries()]) {
      // Rails forms nest attributes like "user[email]" or "issue[title]".
      const bracketMatch = /^([^[]+)\[([^\]]+)\]$/.exec(key);
      const table = bracketMatch ? bracketMatch[1] : "*";
      const field = bracketMatch ? bracketMatch[2] : key;
      if (this.isPiiColumn(table, field) || field === "authenticity_token") {
        this.noteRedactedColumn(this.resolveTableName(table), field);
        params.set(key, this.pseudonymize(value, field));
        changed = true;
      }
    }
    return changed ? params.toString() : body;
  }

  redactJsonBody(body, contextHint = "") {
    if (!body || !body.trim()) return body;
    let parsed;
    try {
      parsed = JSON.parse(body);
    } catch {
      return body;
    }
    const redacted = this.redactSyncPayload(parsed, contextHint);
    return JSON.stringify(redacted);
  }

  redactSyncPayload(payload, contextHint = "") {
    if (!payload || typeof payload !== "object") return payload;
    if (Array.isArray(payload)) {
      return payload.map((item) => this.redactSyncPayload(item, contextHint));
    }
    const copy = { ...payload };
    if (typeof copy.identity === "string" && copy.identity) {
      this.redactedFields.add("identity");
      copy.identity = this.pseudonymize(copy.identity, "identity");
    }
    if (Array.isArray(copy.records)) {
      copy.records = copy.records.map((record) => {
        if (!record || typeof record !== "object") return record;
        const type = record.type || record.record_type || contextHint;
        return {
          ...record,
          attributes: record.attributes ? this.redactRecordAttributes(type, record.attributes) : record.attributes,
        };
      });
    }
    if (Array.isArray(copy.mutations)) {
      copy.mutations = copy.mutations.map((mutation) => {
        if (!mutation || typeof mutation !== "object") return mutation;
        const type = mutation.record_type || mutation.type || contextHint;
        return {
          ...mutation,
          changes: mutation.changes ? this.redactRecordAttributes(type, mutation.changes) : mutation.changes,
        };
      });
    }
    if (Array.isArray(copy.results)) {
      copy.results = copy.results.map((result) => {
        if (!result || typeof result !== "object") return result;
        const type = result.record_type || result.type || contextHint;
        return {
          ...result,
          server_attributes: result.server_attributes
            ? this.redactRecordAttributes(type, result.server_attributes)
            : result.server_attributes,
        };
      });
    }
    if (copy.attributes && typeof copy.attributes === "object" && (copy.type || copy.record_type)) {
      copy.attributes = this.redactRecordAttributes(copy.type || copy.record_type, copy.attributes);
    }
    if (!copy.records && !copy.mutations && !copy.results && !copy.attributes) {
      return this.redactObject(contextHint || "*", copy);
    }
    return copy;
  }

  redactSseChunk(chunk) {
    if (!chunk) return chunk;
    return chunk
      .split("\n")
      .map((line) => {
        if (!line.startsWith("data:")) return line;
        const raw = line.slice(5).trim();
        if (!raw) return line;
        return "data: " + this.redactJsonBody(raw);
      })
      .join("\n");
  }

  redactHttpRequest(rawHttp) {
    const sep = rawHttp.indexOf("\r\n\r\n");
    const headEnd = sep >= 0 ? sep : rawHttp.indexOf("\n\n");
    const lineBreak = sep >= 0 ? "\r\n" : "\n";
    if (headEnd < 0) return rawHttp;

    const head = rawHttp.slice(0, headEnd);
    const body = rawHttp.slice(headEnd + lineBreak.length * 2);
    const lines = head.split(lineBreak);
    if (lines.length === 0) return rawHttp;

    // Request line: METHOD PATH HTTP/1.1
    const parts = lines[0].split(" ");
    if (parts.length >= 2) {
      parts[1] = this.redactUrl(parts[1]);
      lines[0] = parts.join(" ");
    }

    let contentType = "";
    const redactedHeaders = lines.slice(1).map((line) => {
      const colon = line.indexOf(":");
      if (colon < 0) return line;
      const name = line.slice(0, colon).trim();
      const value = line.slice(colon + 1).trim();
      if (name.toLowerCase() === "content-type") contentType = value.toLowerCase();
      if (SENSITIVE_HEADER_RE.test(name)) {
        this.redactedFields.add(name.toLowerCase());
        return `${name}: ${this.pseudonymize(value, name.toLowerCase())}`;
      }
      return line;
    });

    let redactedBody = body;
    if (body) {
      if (contentType.includes("application/json")) {
        redactedBody = this.redactJsonBody(body);
      } else if (contentType.includes("application/x-www-form-urlencoded") || body.includes("=")) {
        redactedBody = this.redactFormBody(body);
      }
    }

    // Keep Content-Length accurate so Tep::Parser can parse the redacted request on replay.
    const bodyByteLen = new TextEncoder().encode(redactedBody).length;
    const finalHeaders = redactedHeaders.map((line) =>
      /^content-length:/i.test(line) ? `Content-Length: ${bodyByteLen}` : line,
    );

    return `${lines[0]}${lineBreak}${finalHeaders.join(lineBreak)}${lineBreak}${lineBreak}${redactedBody}`;
  }

  redactExchange(exchange) {
    if (!exchange || typeof exchange !== "object") return exchange;
    const method = exchange.method || "GET";
    const url = this.redactUrl(exchange.url || "");
    let requestBody = exchange.requestBody || "";
    let responseBody = exchange.responseBody || "";

    if (requestBody) requestBody = this.redactJsonBody(requestBody);
    if (responseBody) {
      if (url.includes("/events") || responseBody.startsWith("id:") || responseBody.startsWith("data:")) {
        responseBody = this.redactSseChunk(responseBody);
      } else {
        responseBody = this.redactJsonBody(responseBody);
      }
    }

    return {
      method,
      url,
      requestBody,
      status: exchange.status,
      responseBody,
    };
  }

  redactWasiInput(exportName, inputBytes) {
    const text = typeof inputBytes === "string" ? inputBytes : decoder.decode(inputBytes || new Uint8Array());
    if (!text) return "";
    switch (exportName) {
      case "wasm_request":
        return this.redactHttpRequest(text);
      case "wasm_sync":
        return this.redactUrl(text);
      case "wasm_stream":
        return this.redactSseChunk(text);
      case "wasm_history": {
        try {
          const parsed = JSON.parse(text);
          return JSON.stringify({
            key: parsed.key ? this.redactUrl("?" + parsed.key).slice(1) : parsed.key,
            response: parsed.response ? this.redactJsonBody(parsed.response) : parsed.response,
          });
        } catch {
          return text;
        }
      }
      default:
        return text;
    }
  }

  redactNotification(event) {
    if (!event || typeof event !== "object") return event;
    return {
      ...event,
      payload: event.payload && typeof event.payload === "object"
        ? this.redactObject("*", event.payload)
        : event.payload,
    };
  }

  manifest() {
    const schemaSummary = {};
    for (const [table, cols] of Object.entries(this.schema)) {
      schemaSummary[table] = cols.map((c) => c.name);
    }
    return {
      enabled: true,
      strategy: "deterministic_pseudonym",
      schema: schemaSummary,
      redactedColumns: Object.fromEntries(
        Object.entries(this.redactedColumns).map(([k, v]) => [k, [...v].sort()]),
      ),
      redactedFields: [...this.redactedFields].sort(),
    };
  }
}

function randomSalt() {
  const bytes = new Uint8Array(16);
  if (globalThis.crypto?.getRandomValues) {
    globalThis.crypto.getRandomValues(bytes);
  } else {
    for (let i = 0; i < bytes.length; i++) bytes[i] = Math.floor(Math.random() * 256);
  }
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}
