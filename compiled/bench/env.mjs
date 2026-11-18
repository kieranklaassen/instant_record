// Shared setup for the benchmark: toolchain paths, the browser driver, and the Rails sync server.
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

export const root = join(dirname(fileURLToPath(import.meta.url)), "..");

export const tools = {};
for (const line of readFileSync(join(root, "toolchain.env"), "utf8").split("\n")) {
  if (!line || line.startsWith("#") || !line.includes("=")) continue;
  const at = line.indexOf("=");
  let value = line.slice(at + 1);
  for (const [name, known] of Object.entries(tools)) value = value.replaceAll("$" + name, known);
  tools[line.slice(0, at)] = value;
}

export const { chromium } = createRequire(tools.PLAYWRIGHT_NODE_MODULES + "/")("playwright-core");

export const RAILS = process.env.RAILS_URL || "http://127.0.0.1:3210";
const PG = ["-h", "127.0.0.1", "-p", "54329", "-U", "demo", "-d", "demo_development", "-At"];
const railsEnv = {
  ...process.env,
  RBENV_VERSION: tools.RBENV_VERSION || process.env.RBENV_VERSION || "3.3.3",
  ...(tools.BUNDLE_PATH ? { BUNDLE_PATH: tools.BUNDLE_PATH } : {}),
  ...(tools.BUNDLE_APP_CONFIG ? { BUNDLE_APP_CONFIG: tools.BUNDLE_APP_CONFIG } : {}),
  DATABASE_URL: "postgres://demo@127.0.0.1:54329/demo_development",
  RAILS_ENV: "development",
};

export function sql(query) {
  const out = spawnSync("psql", [...PG, "-c", query], { encoding: "utf8" });
  if (out.status !== 0) throw new Error("psql: " + out.stderr.slice(0, 300));
  return out.stdout.trim();
}
export const rows = (table, where) => JSON.parse(sql(`select coalesce(json_agg(t), '[]') from (select * from ${table} where ${where} order by created_at) t`));

// A write that originates on the server, through the real model and its Syncable callbacks.
export function runner(ruby) {
  const out = spawnSync("bin/rails", ["runner", ruby], { cwd: join(tools.GEM_SRC, "demo"), env: railsEnv, encoding: "utf8" });
  if (out.status !== 0) throw new Error("rails runner: " + out.stderr.slice(-400));
}

export async function railsUp() {
  try { return (await fetch(RAILS + "/up")).ok; } catch { return false; }
}

// Every run starts from the same server data: the seeded channels, users and backfilled
// messages, no issues, nothing an earlier run wrote.
export function resetServerData() {
  sql("delete from issues");
  sql("delete from messages where id not like 'backfill-%' and id not like 'welcome-%'");
}

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
export async function until(label, fn, timeout = 15000) {
  const start = Date.now();
  for (;;) {
    try { const value = await fn(); if (value) return value; } catch {}
    if (Date.now() - start > timeout) throw new Error("timed out: " + label);
    await sleep(150);
  }
}
export const median = (values) => {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
};
