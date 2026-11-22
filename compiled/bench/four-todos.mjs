// How long each of the four todo apps (/plain, /hotwire, /inertia, /instant) takes to show an
// add, a tick and a delete, on a link that is not a loopback.
//
//   cd demo && npm run build && RAILS_ENV=test bin/rails server -p 3210
//   node compiled/bench/four-todos.mjs                 (the three apps Rails serves)
//
// The fourth app is only itself in a compiled build. With one served (PORT=4174 node
// compiled/bench/serve.mjs), name it and it is timed too:
//
//   INSTANT_URL=http://127.0.0.1:4174 node compiled/bench/four-todos.mjs
//
//   seen_ms     from the input event to the frame that shows the change, read from the page's
//               own stopwatch (demo/app/javascript/controllers/stopwatch_controller.js), which
//               is the number /compare shows.
//   server_ms   from the same input event to the end of the request that carried the write to
//               the server. For the first two apps the page waits for it. For the last two it
//               happens behind the page.
//
// Both are medians over SAMPLES rounds of add, tick, delete with a real keyboard and mouse.
//
//   node compiled/bench/four-todos.mjs --serve         keeps the slow links up and prints the
//                                                      address of /compare, for filming.
import { createRequire } from "node:module";
import { existsSync, readFileSync } from "node:fs";
import { slowLink } from "./link.mjs";

const SAMPLES = Number(process.env.SAMPLES || 10);
const LATENCY_MS = Number(process.env.LATENCY_MS ?? 60);
const MBPS = Number(process.env.MBPS ?? 20);
const RAILS = new URL(process.env.RAILS_URL || "http://127.0.0.1:3210");
const INSTANT = process.env.INSTANT_URL ? new URL(process.env.INSTANT_URL) : null;
const CHANNEL = process.env.BENCH_CHANNEL ?? "none"; // "chrome" for the installed Chrome
const SERVE = process.argv.includes("--serve");

// Playwright from wherever this machine keeps it: named, the toolchain's, or installed.
function playwright() {
  const toolchain = new URL("../toolchain.env", import.meta.url);
  const named = process.env.PLAYWRIGHT_NODE_MODULES
    || (existsSync(toolchain) && readFileSync(toolchain, "utf8").match(/^PLAYWRIGHT_NODE_MODULES=(.+)$/m)?.[1]);
  for (const [from, name] of [[named && named + "/", "playwright-core"], [import.meta.url, "playwright"], ["/opt/node22/lib/node_modules/", "playwright"]]) {
    try { if (from) return createRequire(from)(name); } catch {}
  }
  throw new Error("Playwright not found. Set PLAYWRIGHT_NODE_MODULES to a node_modules folder that has playwright-core.");
}

const link = { latencyMs: LATENCY_MS, mbps: MBPS };
const served = await slowLink({ ...link, port: Number(process.env.LINK_PORT || 4181), upstream: () => RAILS });
const compiled = INSTANT && await slowLink({ ...link, port: Number(process.env.INSTANT_LINK_PORT || 4182),
  upstream: (path) => (/^\/(instant_record|[^/]+\/sync)(\/|$)/.test(path) ? RAILS : INSTANT) });

if (SERVE) {
  console.log(`The link is up: ${LATENCY_MS} ms each way, ${MBPS} Mbit/s.`);
  console.log(`Side by side: ${served}/compare`);
  console.log(compiled
    ? `Start Rails with COMPARE_INSTANT_URL=${compiled}/instant so the fourth pane is the compiled app.`
    : "No INSTANT_URL given: the fourth pane is served by Rails and behaves as the first.");
  await new Promise(() => {});
}

const ways = [
  { way: "plain", origin: served },
  { way: "hotwire", origin: served },
  { way: "inertia", origin: served },
  ...(compiled ? [{ way: "instant", origin: compiled }] : []),
];

const median = (values) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted.length ? Math.round(sorted[Math.floor((sorted.length - 1) / 2)]) : null;
};

const { chromium } = playwright();
const browser = await chromium.launch(CHANNEL === "none" ? {} : { channel: CHANNEL });
const result = { latency_ms: LATENCY_MS, mbps: MBPS, samples: SAMPLES, ways: {} };

for (const { way, origin } of ways) {
  const page = await (await browser.newContext()).newPage();
  const writes = []; // when each write to the server finished, on the clock the page uses
  page.on("requestfinished", (request) => { if (request.method() !== "GET") writes.push(Date.now()); });
  await page.goto(`${origin}/${way}`);
  await page.waitForFunction(() => window.__stopwatch && document.querySelector(".four input[type='text']"), null, { timeout: 60000 });
  await page.evaluate(() => window.postMessage({ type: "four.clear" }, "*"));

  const timed = async (press) => {
    const before = await page.evaluate(() => window.__stopwatch.history.length);
    await press();
    await page.waitForFunction((count) => window.__stopwatch.history.length > count, before, { timeout: 30000 });
    const time = await page.evaluate(() => window.__stopwatch.last);
    // The write reaches the server behind the page in two of the four: wait for it.
    const until = Date.now() + 10000;
    while (!writes.some((at) => at >= time.at) && Date.now() < until) await page.waitForTimeout(20);
    const server = writes.find((at) => at >= time.at);
    await page.waitForLoadState("networkidle").catch(() => {});
    await page.waitForFunction(() => !document.querySelector(".four-list li.pending"));
    return { ...time, server_ms: server ? Math.round(server - time.at) : null };
  };

  const seen = { add: [], toggle: [], delete: [] }, server = { add: [], toggle: [], delete: [] };
  for (let round = 0; round < SAMPLES + 1; round++) {
    const steps = [
      await timed(async () => { await page.fill(".four input[type='text']", `Todo ${round}`); await page.keyboard.press("Enter"); }),
      await timed(() => page.click(".four-list li:first-child input[type='checkbox']")),
      await timed(() => page.click(".four-list li:first-child button")),
    ];
    if (round === 0) continue; // the first round warms the server and the page
    for (const step of steps) { seen[step.action].push(step.ms); server[step.action].push(step.server_ms); }
  }
  result.ways[way] = Object.fromEntries(Object.keys(seen).map((action) =>
    [action, { seen_ms: median(seen[action]), server_ms: median(server[action].filter((ms) => ms !== null)), seen_all: seen[action] }]));
  await page.context().close();
}

await browser.close();
console.log(JSON.stringify(result, null, 2));
process.exit(0);
