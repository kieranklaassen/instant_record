#!/usr/bin/env node
// The benchmark: build this checkout, serve it, measure it, check its behavior. Prints one JSON object.
//
//   node bench/bench.mjs
//
// Environment:
//   BENCH_PORT       port for the static server (default 4184; avoid 4190, which browsers block)
//   BENCH_DIST       serve this folder instead of building (used to prove the gates catch a fake)
//   BENCH_CONTEXTS   fresh browser profiles to measure (default 5)
//
// Needs the Rails sync server on RAILS_URL (default http://127.0.0.1:3210) and its Postgres; it does
// not start them. Server data is reset to the seeded state before measuring.
import { spawn, spawnSync } from "node:child_process";
import { existsSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { root, railsUp, resetServerData, until } from "./env.mjs";
import { measure } from "./measure.mjs";
import { behaviorChecks } from "./e2e.mjs";

const port = Number(process.env.BENCH_PORT || 4184);
const base = `http://127.0.0.1:${port}`;
const result = { build_ok: 0, env_ok: 0, checks_passed: 0, checks_failed: 0 };
const finish = (code = 0) => { console.log(JSON.stringify(result, null, 1)); process.exit(code); };

let dist = process.env.BENCH_DIST;
if (!dist) {
  const started = Date.now();
  const build = spawnSync("python3", [join(root, "pipeline/build.py")], { encoding: "utf8" });
  result.build_seconds = Math.round((Date.now() - started) / 100) / 10;
  if (build.status !== 0) {
    result.build_error = (build.stdout + build.stderr).slice(-800);
    finish();
  }
  dist = join(root, "web/dist");
}
if (!existsSync(join(dist, "index.html"))) { result.build_error = "no index.html in " + dist; finish(); }
result.build_ok = 1;

if (!(await railsUp())) { result.env_error = "the Rails sync server is not answering"; finish(); }
try { resetServerData(); } catch (error) { result.env_error = String(error.message); finish(); }
result.env_ok = 1;

const server = spawn("node", [join(root, "bench/serve.mjs")], { env: { ...process.env, PORT: String(port), DIST: dist }, stdio: ["ignore", "ignore", "inherit"] });
const stop = () => { try { server.kill("SIGTERM"); } catch {} };
process.on("exit", stop);
try {
  await until("static server", async () => (await fetch(base + "/__test/traffic")).ok, 10000);
  // The server compresses each file the first time it is asked for it. Ask once now, so the first
  // measured visit is not charged for compressing an 11 MB module.
  for (const name of readdirSync(dist)) {
    if (name.endsWith(".wasm")) await (await fetch(`${base}/${name}`, { headers: { "accept-encoding": "gzip" } })).arrayBuffer();
  }
  try {
    Object.assign(result, await measure(base));
  } catch (error) {
    result.measure_error = String(error.message).split("\n")[0].slice(0, 300);
  }
  const { cases, failures } = await behaviorChecks(base);
  result.cases = cases;
  result.checks_passed = Object.values(cases).filter(Boolean).length;
  result.checks_failed = Object.values(cases).filter((ok) => !ok).length;
  result.worst_cases = failures; // what went wrong, for the next hypothesis; no gate reads this
} finally {
  stop();
}
finish();
