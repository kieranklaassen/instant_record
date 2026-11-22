// Structured WASM fault telemetry, bridged Ruby notification parsing, and a
// fail-loud circuit breaker shared by AppHost, the browser worker, and Node replay.

export class WasmFaultError extends Error {
  constructor(fault, { cause } = {}) {
    super(fault?.message || "WASM runtime fault", cause ? { cause } : undefined);
    this.name = "WasmFaultError";
    this.fault = fault;
    this.exit = fault?.exit;
    this.errors = Array.isArray(fault?.errors) ? fault.errors.slice() : [];
    this.trapped = !!fault?.trapped;
    this.fatal = !!fault?.fatal;
    this.exportName = fault?.exportName || "";
  }
}

export function isTrapExit(exit) {
  return typeof exit === "string" && exit.startsWith("trap:");
}

export function buildFault({
  exportName,
  exit,
  errors = [],
  trapped = isTrapExit(exit),
  fatal = trapped || exportName === "wasm_boot",
  stack = null,
  at = Date.now(),
}) {
  const stderr = Array.isArray(errors) ? errors.map(String).filter(Boolean) : [];
  const message =
    stderr[0] ||
    (typeof exit === "string" ? exit : `WASM export ${exportName || "unknown"} exited with status ${exit}`);
  const fault = {
    kind: trapped ? "wasm_trap" : "ruby_error",
    exportName: exportName || "unknown",
    exit,
    trapped: !!trapped,
    fatal: !!fatal,
    message,
    errors: stderr,
    at,
  };
  if (stack) fault.stack = String(stack);
  return fault;
}

// Parse bridged ActiveSupport::Notifications written to /host/events by Ruby's
// InstantRecord::Client. Accepts a JSON array (preferred) or NDJSON lines so a
// partial write before a hard trap still degrades safely.
export function readEvents(text) {
  if (!text || !text.trim()) return [];
  const trimmed = text.trim();
  try {
    const parsed = JSON.parse(trimmed);
    if (Array.isArray(parsed)) return parsed.filter((item) => item && typeof item === "object");
    if (parsed && typeof parsed === "object") return [parsed];
  } catch {
    const events = [];
    for (const line of trimmed.split("\n")) {
      if (!line.trim()) continue;
      try {
        const parsed = JSON.parse(line);
        if (parsed && typeof parsed === "object") events.push(parsed);
      } catch {
        // Ignore truncated trailing line if a hard trap interrupted mid-write.
      }
    }
    return events;
  }
  return [];
}

export class CircuitBreaker {
  constructor({ maxConsecutiveFailures = 3, onTrip = null, clock = () => Date.now() } = {}) {
    this.maxConsecutiveFailures = Math.max(1, maxConsecutiveFailures);
    this.onTrip = onTrip;
    this.clock = clock;
    this.state = "closed";
    this.consecutiveByExport = new Map();
    this.consecutiveFailures = 0;
    this.totalFaults = 0;
    this.trippedAt = null;
    this.tripReason = null;
    this.lastFault = null;
  }

  isOpen() {
    return this.state === "open";
  }

  recordSuccess(exportName = null) {
    if (this.state !== "closed") return;
    if (exportName) {
      this.consecutiveByExport.delete(exportName);
      this.consecutiveFailures = Math.max(0, ...this.consecutiveByExport.values());
    } else {
      this.consecutiveByExport.clear();
      this.consecutiveFailures = 0;
    }
  }

  recordFault(fault) {
    const normalized = fault || buildFault({ exportName: "unknown", exit: 1 });
    this.totalFaults += 1;
    const key = normalized.exportName || "unknown";
    const nextCount = (this.consecutiveByExport.get(key) || 0) + 1;
    this.consecutiveByExport.set(key, nextCount);
    this.consecutiveFailures = Math.max(nextCount, ...this.consecutiveByExport.values());
    this.lastFault = normalized;

    let trippedNow = false;
    const shouldTrip =
      normalized.fatal ||
      normalized.trapped ||
      normalized.exportName === "wasm_boot" ||
      nextCount >= this.maxConsecutiveFailures;

    if (shouldTrip && this.state !== "open") {
      this.state = "open";
      this.trippedAt = this.clock();
      this.tripReason = normalized.fatal || normalized.trapped
        ? `fatal ${normalized.kind} in ${normalized.exportName}`
        : `${nextCount} consecutive WASM faults in ${normalized.exportName}`;
      trippedNow = true;
      this.onTrip?.(this.snapshot());
    }

    return {
      trippedNow,
      open: this.isOpen(),
      snapshot: this.snapshot(),
    };
  }

  assertClosed(operation = "operation") {
    if (!this.isOpen()) return;
    const detail = this.lastFault?.message ? `: ${this.lastFault.message}` : "";
    throw new WasmFaultError(
      buildFault({
        exportName: this.lastFault?.exportName || operation,
        exit: this.lastFault?.exit ?? "trap: circuit_open",
        errors: this.lastFault?.errors || [],
        trapped: !!this.lastFault?.trapped,
        fatal: true,
        at: this.clock(),
      }),
      { cause: new Error(`InstantRecord circuit breaker is open during ${operation}${detail}`) },
    );
  }

  reset() {
    this.state = "closed";
    this.consecutiveByExport.clear();
    this.consecutiveFailures = 0;
    this.trippedAt = null;
    this.tripReason = null;
  }

  snapshot() {
    return {
      state: this.state,
      consecutiveFailures: this.consecutiveFailures,
      consecutiveByExport: Object.fromEntries(this.consecutiveByExport.entries()),
      maxConsecutiveFailures: this.maxConsecutiveFailures,
      totalFaults: this.totalFaults,
      trippedAt: this.trippedAt,
      tripReason: this.tripReason,
      lastFault: this.lastFault,
    };
  }
}
