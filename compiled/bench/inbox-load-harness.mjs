#!/usr/bin/env node
// Measurement harness for compiled Inbox load times.
// Rebuilds the Inbox JS bundle and compiled browser site for this checkout,
// serves it via compiled/bench/serve.mjs, runs compiled/bench/inbox-load.mjs
// against the live seeded Rails sync server, and emits one JSON object.
//
// Environment:
//   BENCH_PORT    port for serve.mjs (default 4174)
//   LINK_PORT     port for inbox-load.mjs throttled link proxy (default BENCH_PORT + 6)
//   RAILS_URL     Rails sync server URL (default http://127.0.0.1:3210)
//   BENCH_DIST    serve this folder instead of building (used for validity-gate probes)
//   SAMPLES       cold-visit browser contexts (default 5)
//   RETURNS       return visits per context (default 2)
//   LATENCY_MS    per-request link latency (default 60)
//   MBPS          response pacing rate (default 20)
import { spawn, spawnSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync, symlinkSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { gzipSync } from "node:zlib";

const benchDir = dirname(fileURLToPath(import.meta.url));
const compiledDir = dirname(benchDir);
const repoRoot = dirname(compiledDir);
const demoDir = join(repoRoot, "demo");
const defaultToolchain = join(process.env.HOME || "", ".cache/instant-record-tools/toolchain.env");
const toolchainPath = process.env.INSTANT_RECORD_TOOLCHAIN || join(compiledDir, "toolchain.env");

const port = Number(process.env.BENCH_PORT || 4174);
const linkPort = Number(process.env.LINK_PORT || (port + 6));
const railsUrl = process.env.RAILS_URL || "http://127.0.0.1:3210";
const base = `http://127.0.0.1:${port}`;

const result = {
  build_ok: 0,
  one_paint: 0,
  same_mail: 0,
  page_errors: 1,
};

const finish = (code = 0) => {
  console.log(JSON.stringify(result));
  process.exit(code);
};

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(label, fn, timeout = 15000) {
  const start = Date.now();
  for (;;) {
    try {
      const val = await fn();
      if (val) return val;
    } catch {}
    if (Date.now() - start > timeout) throw new Error("timed out: " + label);
    await sleep(100);
  }
}

// Ensure worktrees inherit the local toolchain.env and demo/node_modules if absent.
if (!existsSync(join(compiledDir, "toolchain.env")) && existsSync(defaultToolchain)) {
  symlinkSync(defaultToolchain, join(compiledDir, "toolchain.env"));
}
const demoNodeModules = join(demoDir, "node_modules");
if (!existsSync(demoNodeModules)) {
  const fallbackDemoModules = process.env.DEMO_NODE_MODULES
    || "/Users/kieranklaassen/.t3/worktrees/instant_record/optimize-inbox-load-spe-f1f2eb94e282ea8c/demo/node_modules";
  if (existsSync(fallbackDemoModules)) {
    symlinkSync(fallbackDemoModules, demoNodeModules);
  } else {
    const install = spawnSync("npm", ["ci"], { cwd: demoDir, encoding: "utf8" });
    if (install.status !== 0) {
      result.build_error = "demo npm ci failed: " + (install.stdout + install.stderr).slice(-600);
      finish();
    }
  }
}

let dist = process.env.BENCH_DIST;
if (!dist) {
  const started = Date.now();
  const viteBin = join(demoDir, "node_modules/.bin/vite");
  const vite = spawnSync(viteBin, ["build"], { cwd: demoDir, encoding: "utf8" });
  if (vite.status !== 0) {
    result.build_error = "vite build failed: " + (vite.stdout + vite.stderr).slice(-600);
    finish();
  }
  const build = spawnSync("python3", [join(compiledDir, "pipeline/build.py")], {
    cwd: repoRoot,
    env: { ...process.env, INSTANT_RECORD_TOOLCHAIN: existsSync(toolchainPath) ? toolchainPath : defaultToolchain },
    encoding: "utf8",
  });
  result.build_seconds = Math.round((Date.now() - started) / 100) / 10;
  if (build.status !== 0) {
    result.build_error = "build.py failed: " + (build.stdout + build.stderr).slice(-800);
    finish();
  }
  dist = join(compiledDir, "web/dist");
} else {
  result.build_seconds = 0;
}

if (!existsSync(join(dist, "index.html"))) {
  result.build_error = "no index.html in " + dist;
  finish();
}
result.build_ok = 1;

// Artifact size diagnostics
try {
  const wasmFile = readdirSync(dist).find((name) => name.endsWith(".wasm"));
  if (wasmFile) {
    const bytes = readFileSync(join(dist, wasmFile));
    result.wasm_raw_bytes = bytes.length;
    result.wasm_gzip_bytes = gzipSync(bytes).length;
    const brPath = join(dist, wasmFile + ".br");
    if (existsSync(brPath)) result.wasm_br_bytes = readFileSync(brPath).length;
  }
  const inboxJsPath = join(dist, "assets/inbox.js");
  if (existsSync(inboxJsPath)) {
    const jsBytes = readFileSync(inboxJsPath);
    result.inbox_js_bytes = jsBytes.length;
    result.inbox_js_gzip_bytes = gzipSync(jsBytes).length;
  }
} catch {}

// Verify Rails sync server is reachable before launching browser.
try {
  const up = await fetch(railsUrl + "/up");
  if (!up.ok) throw new Error("status " + up.status);
} catch (error) {
  result.env_error = "Rails sync server not answering at " + railsUrl + ": " + error.message;
  finish();
}

const server = spawn("node", [join(benchDir, "serve.mjs")], {
  env: { ...process.env, PORT: String(port), DIST: dist },
  stdio: ["ignore", "ignore", "inherit"],
});
const stop = () => { try { server.kill("SIGTERM"); } catch {} };
process.on("exit", stop);

try {
  await until("static server", async () => (await fetch(base + "/__test/traffic")).ok, 10000);
  // Pre-warm compression cache so sample 0 is not charged for compressing Wasm on the fly.
  for (const name of readdirSync(dist)) {
    if (name.endsWith(".wasm")) {
      await (await fetch(`${base}/${name}`, { headers: { "accept-encoding": "br, gzip" } })).arrayBuffer();
      await (await fetch(`${base}/${name}`, { headers: { "accept-encoding": "gzip" } })).arrayBuffer();
    }
  }

  const bench = spawnSync("node", [join(benchDir, "inbox-load.mjs")], {
    cwd: repoRoot,
    env: {
      ...process.env,
      STATIC_URL: base,
      RAILS_URL: railsUrl,
      LINK_PORT: String(linkPort),
    },
    encoding: "utf8",
    timeout: 540000,
  });

  if (bench.status !== 0) {
    result.measure_error = (bench.stderr || bench.stdout || "inbox-load.mjs exited " + bench.status).slice(-800);
    finish();
  }

  const lines = bench.stdout.trim().split("\n").filter(Boolean);
  const parsed = JSON.parse(lines.at(-1));
  Object.assign(result, parsed);
} catch (error) {
  result.measure_error = String(error.message || error).slice(0, 400);
} finally {
  stop();
}

finish();
