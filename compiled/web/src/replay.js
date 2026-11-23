// Deterministic `.irtrace` flight-recorder replayer in Node AppHost.
// Invoked directly via `node compiled/web/src/replay.js <trace.irtrace> --wasm <app.wasm>`
// or via `bin/rails instant_record:replay <trace.irtrace>`.
import { existsSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createAppHostClass } from "./app-host-core.js";
import { TRACE_FORMAT, TRACE_VERSION } from "./flight-recorder.js";
import { base64ToBytes, sha256Hex } from "./sha256.js";
import * as minimalWasi from "./wasi-minimal.js";

const encoder = new TextEncoder();

export async function loadWasiShim(extraNodeModules = []) {
  const candidates = [];
  for (const dir of extraNodeModules) {
    if (dir) candidates.push(resolve(dir));
  }
  if (process.env.INSTANT_RECORD_WEB_NODE_MODULES) {
    candidates.push(resolve(process.env.INSTANT_RECORD_WEB_NODE_MODULES));
  }
  const webRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
  candidates.push(join(webRoot, "node_modules"));

  for (const dir of candidates) {
    const pkgDir = join(dir, "@bjorn3", "browser_wasi_shim");
    const pkgJsonPath = join(pkgDir, "package.json");
    if (!existsSync(pkgJsonPath)) continue;
    try {
      const pkg = JSON.parse(readFileSync(pkgJsonPath, "utf8"));
      const entry =
        pkg.exports?.["."]?.import ||
        pkg.exports?.["."]?.default ||
        pkg.module ||
        pkg.main ||
        "dist/index.js";
      const loaded = await import(pathToFileURL(join(pkgDir, entry)).href);
      if (loaded?.WASI) return { shim: loaded, source: pkgDir };
    } catch {
      try {
        const req = createRequire(join(dir, "_noop.js"));
        const loaded = req("@bjorn3/browser_wasi_shim");
        if (loaded?.WASI) return { shim: loaded, source: pkgDir };
      } catch {
        // Fall through to next candidate.
      }
    }
  }
  return { shim: minimalWasi, source: "wasi-minimal" };
}

export function decodeStepInput(input) {
  if (!input) return new Uint8Array();
  if (input instanceof Uint8Array) return input;
  if (typeof input === "string") return encoder.encode(input);
  if (input.encoding === "base64") return base64ToBytes(input.data || "");
  return encoder.encode(input.data || "");
}

export function validateTrace(trace) {
  if (!trace || typeof trace !== "object") throw new Error("Trace file must be a JSON object");
  if (trace.format !== TRACE_FORMAT) {
    throw new Error(`Unsupported trace format ${JSON.stringify(trace.format)} (expected ${JSON.stringify(TRACE_FORMAT)})`);
  }
  if (trace.version !== TRACE_VERSION) {
    throw new Error(`Unsupported trace version ${trace.version} (expected ${TRACE_VERSION})`);
  }
  if (!Array.isArray(trace.steps)) {
    throw new Error("Trace is missing a steps array");
  }
  return trace;
}

export async function replayTrace(
  trace,
  {
    wasmModule = null,
    wasmBytes = null,
    wasmPath = null,
    dbBytes = null,
    allowDigestMismatch = false,
    stopOnFault = false,
    maxSteps = null,
    nodeModules = [],
    wasiShim = null,
  } = {},
) {
  validateTrace(trace);

  let module = wasmModule;
  if (!module) {
    const raw = wasmBytes || (wasmPath ? new Uint8Array(readFileSync(wasmPath)) : null);
    if (!raw) throw new Error("Replay requires a WASM module (pass --wasm <path> or WASM=<path>)");
    module = new WebAssembly.Module(raw);
  }

  const resolvedWasi = wasiShim ? { shim: wasiShim, source: "injected" } : await loadWasiShim(nodeModules);
  const AppHost = createAppHostClass(resolvedWasi.shim);

  const checkpoint = trace.checkpoint || { mode: "empty" };
  let initialDb = null;
  if (dbBytes) {
    initialDb = dbBytes instanceof Uint8Array ? dbBytes : new Uint8Array(dbBytes);
  } else if (checkpoint.mode === "sqlite3" && checkpoint.data) {
    initialDb = base64ToBytes(checkpoint.data);
  } else if (checkpoint.mode === "digest") {
    throw new Error(
      `Trace checkpoint is digest-only (${checkpoint.omittedReason || "no embedded DB"}); supply matching SQLite file with --db <path> (expected sha256:${checkpoint.digest})`,
    );
  }

  let actualDbDigest = null;
  if (initialDb) {
    actualDbDigest = sha256Hex(initialDb);
    if (checkpoint.digest && actualDbDigest !== checkpoint.digest && !allowDigestMismatch) {
      throw new Error(
        `Base DB digest mismatch: expected ${checkpoint.digest}, got ${actualDbDigest} (pass --allow-digest-mismatch to override)`,
      );
    }
  }

  let activeExchanges = [];
  let exchangeIndex = 0;
  let exchangeMismatchError = null;

  const replayExchange = (method, url, requestBody) => {
    if (exchangeIndex >= activeExchanges.length) {
      exchangeMismatchError = new Error(
        `Unexpected network exchange during replay: ${method} ${url} (recorded ${activeExchanges.length} exchange(s) for this step)`,
      );
      throw exchangeMismatchError;
    }
    const recorded = activeExchanges[exchangeIndex++];
    if (recorded.method && recorded.method !== method) {
      exchangeMismatchError = new Error(
        `Exchange method mismatch at index ${exchangeIndex - 1}: expected ${recorded.method}, got ${method}`,
      );
      throw exchangeMismatchError;
    }
    if (recorded.url && recorded.url !== url) {
      exchangeMismatchError = new Error(
        `Exchange URL mismatch at index ${exchangeIndex - 1}: expected ${recorded.url}, got ${url}`,
      );
      throw exchangeMismatchError;
    }
    return {
      status: recorded.status ?? 0,
      body: recorded.responseBody ?? "",
      requestBody,
    };
  };

  const host = new AppHost(module, {
    env: checkpoint.env || {},
    exchange: replayExchange,
  });

  if (checkpoint.cookies && typeof checkpoint.cookies === "object") {
    for (const [k, v] of Object.entries(checkpoint.cookies)) host.cookies.set(k, v);
  }
  if (initialDb) {
    host.restoreDatabase(initialDb, checkpoint.schemaVersion || 0);
  }

  let bootFault = null;
  try {
    host.ensureBooted();
  } catch (error) {
    bootFault = error.fault || { kind: "wasm_trap", exportName: "wasm_boot", message: error.message, errors: error.errors || [] };
    return {
      ok: false,
      wasiSource: resolvedWasi.source,
      checkpointDigest: actualDbDigest,
      bootFault,
      reproducedFault: true,
      mismatches: 0,
      steps: [],
    };
  }

  const stepsToRun = maxSteps != null ? trace.steps.slice(0, Number(maxSteps)) : trace.steps;
  const results = [];
  let mismatches = 0;
  let reproducedFault = false;

  for (const step of stepsToRun) {
    activeExchanges = Array.isArray(step.exchanges) ? step.exchanges : [];
    exchangeIndex = 0;
    exchangeMismatchError = null;

    const inputBytes = decodeStepInput(step.input);
    const actual = host.call(step.exportName, inputBytes);
    const actualOutDigest = actual.out ? sha256Hex(actual.out) : null;
    const expected = step.outcome || {};

    const exitMatches = expected.exit === undefined ? true : actual.exit === expected.exit;
    const trappedMatches = expected.trapped === undefined ? true : actual.trapped === expected.trapped;
    const outDigestMatches = !expected.outDigest ? true : actualOutDigest === expected.outDigest;
    const exchangesConsumed = !exchangeMismatchError && exchangeIndex === activeExchanges.length;
    const matched = exitMatches && trappedMatches && outDigestMatches && exchangesConsumed;

    if (!matched) mismatches += 1;
    if (actual.fault && expected.fault) reproducedFault = true;

    results.push({
      seq: step.seq,
      exportName: step.exportName,
      matched,
      exitMatches,
      trappedMatches,
      outDigestMatches,
      exchangesConsumed,
      exchangeError: exchangeMismatchError ? exchangeMismatchError.message : null,
      expected: {
        exit: expected.exit,
        trapped: !!expected.trapped,
        errors: expected.errors || [],
        outDigest: expected.outDigest || null,
        events: expected.events || [],
      },
      actual: {
        exit: actual.exit,
        trapped: !!actual.trapped,
        errors: actual.errors || [],
        outDigest: actualOutDigest,
        events: actual.events || [],
        fault: actual.fault || null,
      },
    });

    if (host.poisoned || (stopOnFault && actual.fault)) break;
  }

  return {
    ok: mismatches === 0,
    wasiSource: resolvedWasi.source,
    checkpointDigest: actualDbDigest,
    bootFault: null,
    reproducedFault,
    mismatches,
    totalSteps: stepsToRun.length,
    executedSteps: results.length,
    steps: results,
  };
}

export function formatReplayReport(report) {
  const lines = [];
  lines.push(`InstantRecord deterministic replay (${report.wasiSource})`);
  if (report.checkpointDigest) lines.push(`  checkpoint sha256: ${report.checkpointDigest}`);
  if (report.bootFault) {
    lines.push(`  [BOOT FAULT] ${report.bootFault.message}`);
    for (const err of report.bootFault.errors || []) lines.push(`    stderr: ${err}`);
    return lines.join("\n");
  }
  for (const step of report.steps) {
    const tag = step.actual.fault
      ? (step.matched ? "FAULT REPRODUCED" : "FAULT")
      : (step.matched ? "OK" : "DIVERGED");
    lines.push(
      `  #${step.seq} ${step.exportName} -> exit=${JSON.stringify(step.actual.exit)} (expected ${JSON.stringify(step.expected.exit)}) [${tag}]`,
    );
    for (const err of step.actual.errors) lines.push(`    stderr: ${err}`);
    for (const ev of step.actual.events) {
      lines.push(`    event: ${ev.name} ${JSON.stringify(ev.payload || {})}`);
    }
    if (!step.matched) {
      if (!step.outDigestMatches) {
        lines.push(`    outDigest mismatch: actual=${step.actual.outDigest} expected=${step.expected.outDigest}`);
      }
      if (!step.exchangesConsumed) {
        lines.push(`    unconsumed exchanges in step #${step.seq}`);
      }
    }
  }
  lines.push(
    `Summary: ${report.executedSteps}/${report.totalSteps} step(s) replayed, ${report.mismatches} divergence(s)` +
      (report.reproducedFault ? ", recorded fault reproduced" : ""),
  );
  return lines.join("\n");
}

function parseCliArgs(argv) {
  const opts = {
    tracePath: null,
    wasmPath: null,
    dbPath: null,
    nodeModules: [],
    json: false,
    allowDigestMismatch: false,
    stopOnFault: false,
    maxSteps: null,
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--wasm" && argv[i + 1]) opts.wasmPath = argv[++i];
    else if (arg === "--db" && argv[i + 1]) opts.dbPath = argv[++i];
    else if (arg === "--node-modules" && argv[i + 1]) opts.nodeModules.push(argv[++i]);
    else if (arg === "--max-steps" && argv[i + 1]) opts.maxSteps = Number(argv[++i]);
    else if (arg === "--json") opts.json = true;
    else if (arg === "--allow-digest-mismatch") opts.allowDigestMismatch = true;
    else if (arg === "--stop-on-fault") opts.stopOnFault = true;
    else if (!arg.startsWith("-") && !opts.tracePath) opts.tracePath = arg;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  return opts;
}

const isCli = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isCli) {
  try {
    const opts = parseCliArgs(process.argv.slice(2));
    if (!opts.tracePath) {
      console.error("Usage: node replay.js <file.irtrace> --wasm <app.wasm> [--db <file.sqlite3>] [--json] [--stop-on-fault]");
      process.exit(2);
    }
    const trace = JSON.parse(readFileSync(opts.tracePath, "utf8"));
    const dbBytes = opts.dbPath ? new Uint8Array(readFileSync(opts.dbPath)) : null;
    const report = await replayTrace(trace, {
      wasmPath: opts.wasmPath,
      dbBytes,
      allowDigestMismatch: opts.allowDigestMismatch,
      stopOnFault: opts.stopOnFault,
      maxSteps: opts.maxSteps,
      nodeModules: opts.nodeModules,
    });
    if (opts.json) {
      console.log(JSON.stringify(report, null, 2));
    } else {
      console.log(formatReplayReport(report));
    }
    process.exit(report.ok ? 0 : 1);
  } catch (error) {
    console.error(`Replay error: ${error.message}`);
    process.exit(1);
  }
}
