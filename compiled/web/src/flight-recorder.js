// Opt-in rolling flight recorder for InstantRecord's WASI reactor boundary.
// Uses a two-epoch ring buffer so exported `.irtrace` files always start from
// a consistent base DB checkpoint (with SHA-256 digest and schema-aware PII
// redaction) immediately preceding `steps[0]`.
import { Redactor } from "./redactor.js";
import { bytesToBase64, sha256Hex } from "./sha256.js";

export const TRACE_FORMAT = "instant_record.trace";
export const TRACE_VERSION = 1;
const DEFAULT_MAX_ENTRIES = 100;
const DEFAULT_MAX_CHECKPOINT_BYTES = 8 * 1024 * 1024;
const decoder = new TextDecoder();

function isValidUtf8(bytes) {
  try {
    new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    return true;
  } catch {
    return false;
  }
}

function copyBytes(bytes) {
  if (!bytes) return null;
  const arr = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  return arr.slice();
}

export class FlightRecorder {
  constructor({
    enabled = false,
    maxEntries = DEFAULT_MAX_ENTRIES,
    checkpointEvery = null,
    maxCheckpointBytes = DEFAULT_MAX_CHECKPOINT_BYTES,
    schema = {},
    piiColumns = {},
    safeColumns = {},
    salt = null,
    clock = () => Date.now(),
  } = {}) {
    this.enabled = !!enabled;
    this.maxEntries = Math.max(1, Number(maxEntries) || DEFAULT_MAX_ENTRIES);
    this.checkpointEvery = Math.max(1, Number(checkpointEvery) || Math.max(1, Math.floor(this.maxEntries / 2)));
    this.maxCheckpointBytes = Math.max(0, Number(maxCheckpointBytes) || DEFAULT_MAX_CHECKPOINT_BYTES);
    this.schema = schema || {};
    this.piiColumns = piiColumns || {};
    this.safeColumns = safeColumns || {};
    this.salt = salt || null;
    this.clock = clock;

    this.seq = 0;
    this.droppedEntries = 0;
    this.epochs = [];
    this.faults = [];
    this.meta = {};
  }

  configure(options = {}) {
    if (typeof options.enabled === "boolean") this.enabled = options.enabled;
    if (options.maxEntries != null) {
      this.maxEntries = Math.max(1, Number(options.maxEntries) || DEFAULT_MAX_ENTRIES);
      this.checkpointEvery = Math.max(1, Number(options.checkpointEvery) || Math.max(1, Math.floor(this.maxEntries / 2)));
    }
    if (options.checkpointEvery != null) {
      this.checkpointEvery = Math.max(1, Number(options.checkpointEvery));
    }
    if (options.maxCheckpointBytes != null) {
      this.maxCheckpointBytes = Math.max(0, Number(options.maxCheckpointBytes));
    }
    if (options.schema) this.schema = options.schema;
    if (options.piiColumns) this.piiColumns = options.piiColumns;
    if (options.safeColumns) this.safeColumns = options.safeColumns;
    if (options.salt) this.salt = options.salt;
    if (options.meta) this.meta = { ...this.meta, ...options.meta };
    if (!this.enabled) return this.status();
    return this.status();
  }

  clear() {
    this.epochs = [];
    this.faults = [];
    this.droppedEntries = 0;
    this.seq = 0;
  }

  captureCheckpoint({ dbBytes = null, schemaVersion = 0, env = {}, cookies = {} } = {}) {
    if (!this.enabled) return null;
    const copied = copyBytes(dbBytes);
    const checkpoint = {
      capturedAt: this.clock(),
      dbBytes: copied,
      digest: copied ? sha256Hex(copied) : null,
      byteLength: copied ? copied.length : 0,
      schemaVersion: Number(schemaVersion) || 0,
      env: { ...env },
      cookies: cookies instanceof Map ? Object.fromEntries(cookies.entries()) : { ...(cookies || {}) },
    };
    this.epochs = [{ checkpoint, steps: [] }];
    return checkpoint;
  }

  ensureEpoch(hostSnapshot) {
    if (this.epochs.length === 0) {
      this.captureCheckpoint(hostSnapshot || {});
      return;
    }
    const newest = this.epochs[this.epochs.length - 1];
    if (newest.steps.length >= this.checkpointEvery && hostSnapshot) {
      const copied = copyBytes(hostSnapshot.dbBytes);
      this.epochs.push({
        checkpoint: {
          capturedAt: this.clock(),
          dbBytes: copied,
          digest: copied ? sha256Hex(copied) : null,
          byteLength: copied ? copied.length : 0,
          schemaVersion: Number(hostSnapshot.schemaVersion) || 0,
          env: { ...(hostSnapshot.env || {}) },
          cookies: hostSnapshot.cookies instanceof Map
            ? Object.fromEntries(hostSnapshot.cookies.entries())
            : { ...(hostSnapshot.cookies || {}) },
        },
        steps: [],
      });
    }
  }

  recordStep({ exportName, inputBytes, exchanges = [], outcome = {}, preCallSnapshot = null }) {
    if (!this.enabled) return null;
    this.ensureEpoch(preCallSnapshot);

    const bytes = copyBytes(inputBytes) || new Uint8Array();
    const step = {
      seq: ++this.seq,
      at: this.clock(),
      exportName,
      inputBytes: bytes,
      exchanges: exchanges.map((ex) => ({
        method: ex.method,
        url: ex.url,
        requestBody: ex.requestBody ?? "",
        status: ex.status ?? 0,
        responseBody: ex.responseBody ?? "",
      })),
      outcome: {
        exit: outcome.exit,
        trapped: !!outcome.trapped,
        errors: Array.isArray(outcome.errors) ? outcome.errors.slice() : [],
        outDigest: outcome.out ? sha256Hex(outcome.out) : null,
        outByteLength: outcome.out ? outcome.out.length : 0,
        events: Array.isArray(outcome.events) ? outcome.events.map((e) => ({ ...e })) : [],
        fault: outcome.fault ? { ...outcome.fault } : null,
      },
    };

    const current = this.epochs[this.epochs.length - 1];
    current.steps.push(step);

    if (step.outcome.fault) {
      this.faults.push({ seq: step.seq, ...step.outcome.fault });
      if (this.faults.length > this.maxEntries) this.faults.shift();
    }

    this.pruneEpochs();
    return step;
  }

  pruneEpochs() {
    while (this.epochs.length > 1 && this.totalSteps() > this.maxEntries) {
      const dropped = this.epochs.shift();
      this.droppedEntries += dropped.steps.length;
    }
  }

  totalSteps() {
    return this.epochs.reduce((sum, epoch) => sum + epoch.steps.length, 0);
  }

  status() {
    const base = this.epochs[0]?.checkpoint || null;
    return {
      enabled: this.enabled,
      maxEntries: this.maxEntries,
      stepCount: this.totalSteps(),
      epochCount: this.epochs.length,
      droppedEntries: this.droppedEntries,
      faultCount: this.faults.length,
      baseDigest: base?.digest || null,
      baseByteLength: base?.byteLength || 0,
    };
  }

  exportTrace({
    redact = true,
    includeUnredactedDatabase = false,
    redactDatabase = null,
    meta = {},
    circuit = null,
  } = {}) {
    const redactor = redact
      ? new Redactor({
          schema: this.schema,
          piiColumns: this.piiColumns,
          safeColumns: this.safeColumns,
          salt: this.salt,
        })
      : null;

    const baseEpoch = this.epochs[0] || null;
    const base = baseEpoch?.checkpoint || null;
    const allSteps = this.epochs.flatMap((epoch) => epoch.steps);

    let checkpoint;
    if (!base || !base.dbBytes || base.dbBytes.length === 0) {
      checkpoint = {
        mode: "empty",
        digest: null,
        originalDigest: null,
        byteLength: 0,
        schemaVersion: base?.schemaVersion || 0,
        encoding: null,
        data: null,
        redacted: true,
        cookies: redactor ? redactor.redactCookies(base?.cookies || {}) : { ...(base?.cookies || {}) },
        env: redactor ? redactor.redactEnv(base?.env || {}) : { ...(base?.env || {}) },
      };
    } else if (base.dbBytes.length > this.maxCheckpointBytes) {
      checkpoint = {
        mode: "digest",
        digest: base.digest,
        originalDigest: base.digest,
        byteLength: base.byteLength,
        schemaVersion: base.schemaVersion,
        encoding: null,
        data: null,
        redacted: true,
        omittedReason: "exceeds_budget",
        cookies: redactor ? redactor.redactCookies(base.cookies) : { ...base.cookies },
        env: redactor ? redactor.redactEnv(base.env) : { ...base.env },
      };
    } else if (!redact || includeUnredactedDatabase) {
      checkpoint = {
        mode: "sqlite3",
        digest: base.digest,
        originalDigest: base.digest,
        byteLength: base.byteLength,
        schemaVersion: base.schemaVersion,
        encoding: "base64",
        data: bytesToBase64(base.dbBytes),
        redacted: false,
        cookies: redactor ? redactor.redactCookies(base.cookies) : { ...base.cookies },
        env: redactor ? redactor.redactEnv(base.env) : { ...base.env },
      };
    } else if (typeof redactDatabase === "function") {
      const dbResult = redactDatabase(base.dbBytes, redactor);
      const redactedBytes = copyBytes(dbResult.bytes);
      checkpoint = {
        mode: "sqlite3",
        digest: dbResult.digest || sha256Hex(redactedBytes),
        originalDigest: base.digest,
        byteLength: redactedBytes.length,
        schemaVersion: base.schemaVersion,
        encoding: "base64",
        data: bytesToBase64(redactedBytes),
        redacted: true,
        redactedColumns: dbResult.redactedColumns || {},
        cookies: redactor.redactCookies(base.cookies),
        env: redactor.redactEnv(base.env),
      };
    } else if (!redactor.hasSchemaPii()) {
      checkpoint = {
        mode: "sqlite3",
        digest: base.digest,
        originalDigest: base.digest,
        byteLength: base.byteLength,
        schemaVersion: base.schemaVersion,
        encoding: "base64",
        data: bytesToBase64(base.dbBytes),
        redacted: true,
        redactedColumns: {},
        cookies: redactor.redactCookies(base.cookies),
        env: redactor.redactEnv(base.env),
      };
    } else {
      checkpoint = {
        mode: "digest",
        digest: base.digest,
        originalDigest: base.digest,
        byteLength: base.byteLength,
        schemaVersion: base.schemaVersion,
        encoding: null,
        data: null,
        redacted: true,
        omittedReason: "pii_redaction_required",
        piiColumns: redactor.schemaPiiMap(),
        cookies: redactor.redactCookies(base.cookies),
        env: redactor.redactEnv(base.env),
      };
    }

    const steps = allSteps.map((step) => {
      const utf8 = isValidUtf8(step.inputBytes);
      let input;
      if (utf8) {
        const rawText = decoder.decode(step.inputBytes);
        input = {
          encoding: "utf8",
          data: redactor ? redactor.redactWasiInput(step.exportName, rawText) : rawText,
        };
      } else {
        input = {
          encoding: "base64",
          data: bytesToBase64(step.inputBytes),
        };
      }
      return {
        seq: step.seq,
        at: step.at,
        exportName: step.exportName,
        input,
        exchanges: step.exchanges.map((ex) => (redactor ? redactor.redactExchange(ex) : { ...ex })),
        outcome: {
          ...step.outcome,
          events: step.outcome.events.map((ev) => (redactor ? redactor.redactNotification(ev) : { ...ev })),
        },
      };
    });

    return {
      format: TRACE_FORMAT,
      version: TRACE_VERSION,
      recordedAt: new Date(this.clock()).toISOString(),
      meta: {
        ...this.meta,
        ...meta,
        maxEntries: this.maxEntries,
        droppedEntries: this.droppedEntries,
      },
      redaction: redactor
        ? redactor.manifest()
        : { enabled: false, strategy: "none", schema: {}, redactedColumns: {}, redactedFields: [] },
      checkpoint,
      steps,
      faults: this.faults.map((f) => ({ ...f })),
      circuit: circuit || null,
    };
  }
}
