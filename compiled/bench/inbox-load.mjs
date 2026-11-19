// How long the Inbox takes to show its mail in a compiled build, on a link that is not a
// loopback: every request waits LATENCY_MS and every response is paced to MBPS.
//
//   cd demo && RAILS_ENV=test bin/rails runner script/seed_offline_inbox.rb
//   RAILS_ENV=test bin/rails server -p 3210          (the sync server)
//   PORT=4174 node compiled/bench/serve.mjs          (the compiled site)
//   node compiled/bench/inbox-load.mjs               (prints one JSON object)
//
//   first_visit_ms    a new browser profile -> /email -> the first frame with mail laid out and
//                     painted. The download, the wasm compile, the bootstrap, the first render.
//   return_visit_ms   the same profile again, its files cached and its database saved and whole.
//
// Both are medians, timed on the page's own clock (a driver-side wait is charged ~80 ms it did
// not spend). A load with no mail in it never stamps a time, so an empty page cannot score.
import { createServer, request as httpRequest } from "node:http";
import { chromium, median } from "./env.mjs";

const SAMPLES = Number(process.env.SAMPLES || 5);
const RETURNS = Number(process.env.RETURNS || 2);
const LATENCY_MS = Number(process.env.LATENCY_MS ?? 60);
const MBPS = Number(process.env.MBPS ?? 20);
const STATIC = new URL(process.env.STATIC_URL || "http://127.0.0.1:4174");
const RAILS = new URL(process.env.RAILS_URL || "http://127.0.0.1:3210");
const PATH = process.env.INBOX_PATH || "/email?member=maya&inbox=support";
const PORT = Number(process.env.LINK_PORT || 4180);
const CHANNEL = process.env.BENCH_CHANNEL ?? "chrome"; // "none" where only Playwright's Chromium is installed

// The link: one origin in front of the site and the sync server, slow in both of the ways a
// real one is. Bodies pass through as they were sent (gzip stays gzip, a stream stays a stream).
const sent = [];
const bytesPerMs = MBPS * 1e6 / 8 / 1000;
const link = createServer((request, response) => {
  const upstream = /^\/(instant_record|[^/]+\/sync)(\/|$)/.test(request.url) ? RAILS : STATIC;
  const entry = { path: request.url, bytes: 0 };
  sent.push(entry);
  setTimeout(() => {
    const forward = httpRequest({ host: upstream.hostname, port: upstream.port, path: request.url, method: request.method,
      headers: { ...request.headers, host: upstream.host } }, (answer) => {
      response.writeHead(answer.statusCode, answer.headers);
      let due = performance.now();
      answer.on("data", (chunk) => {
        entry.bytes += chunk.length;
        due = Math.max(due, performance.now()) + chunk.length / bytesPerMs;
        const wait = due - performance.now();
        if (wait < 1) return response.write(chunk);
        answer.pause();
        setTimeout(() => { response.write(chunk); answer.resume(); }, wait);
      });
      answer.on("end", () => setTimeout(() => response.end(), Math.max(0, due - performance.now())));
      answer.on("error", () => response.destroy());
    });
    forward.on("error", () => response.destroy());
    response.on("close", () => forward.destroy());
    request.pipe(forward);
  }, LATENCY_MS);
});
await new Promise((resolve) => link.listen(PORT, "127.0.0.1", resolve));
const origin = `http://127.0.0.1:${PORT}`;

// Runs in every document before its own scripts. Stamps the first frame in which a mail row is
// laid out and the page is not held unpainted, and keeps each state the page was painted in.
const probe = () => {
  window.__load = { at: undefined, frames: [], errors: [] };
  window.addEventListener("error", (event) => window.__load.errors.push(String(event.message)));
  window.addEventListener("unhandledrejection", (event) => window.__load.errors.push(String(event.reason)));
  const tick = () => {
    const body = document.body;
    if (body && body.childElementCount && getComputedStyle(body).visibility !== "hidden") {
      const row = document.querySelector(".mail-row");
      const state = { list: !!document.querySelector(".mail-list"), rows: !!row };
      const last = window.__load.frames.at(-1);
      if (!last || last.list !== state.list || last.rows !== state.rows) window.__load.frames.push(state);
      if (row && window.__load.at === undefined) {
        const box = row.getBoundingClientRect();
        if (box.width > 0 && box.height > 0) window.__load.at = performance.now();
      }
    }
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
};

const load = async (page) => {
  const started = Date.now();
  await page.goto(origin + PATH);
  await page.waitForFunction(() => window.__load?.at !== undefined, null, { timeout: 30000 });
  await page.waitForTimeout(300); // a second paint, if there is one, comes within this
  const seen = await page.evaluate(() => ({
    origin: performance.timeOrigin, at: window.__load.at, frames: window.__load.frames, errors: window.__load.errors,
    top: document.querySelector(".mail-row strong")?.textContent, rows: document.querySelectorAll(".mail-row").length,
    ledger: window.__spinel?.ledger,
  }));
  return { ...seen, ms: seen.origin - started + seen.at, onePaint: seen.frames.length === 1 && seen.frames[0].list && seen.frames[0].rows };
};

const browser = await chromium.launch(CHANNEL === "none" ? {} : { channel: CHANNEL });
const first = [], again = [], loads = [], phases = {};
let firstBytes = 0, firstRequests = 0;
try {
  for (let sample = 0; sample < SAMPLES; sample++) {
    const context = await browser.newContext({ viewport: { width: 1400, height: 900 } });
    await context.addInitScript(probe);
    sent.length = 0;
    const page = await context.newPage();
    const cold = await load(page);
    first.push(cold.ms);
    loads.push(cold);
    if (sample === 0) {
      firstRequests = sent.length;
      firstBytes = sent.reduce((sum, entry) => sum + entry.bytes, 0);
    }
    for (const entry of cold.ledger?.entries ?? []) (phases[entry.phase] ||= []).push(entry.ms);
    // A return visit is to an inbox that has finished coming down and has been saved.
    await page.waitForFunction(() => window.__spinel?.history?.done === true, null, { timeout: 120000 });
    await page.waitForTimeout(1500);
    await page.close();
    for (let visit = 0; visit < RETURNS; visit++) {
      const back = await context.newPage();
      const warm = await load(back);
      again.push(warm.ms);
      loads.push(warm);
      await back.close();
    }
    await context.close();
  }
} finally {
  await browser.close();
  link.close();
  link.closeAllConnections();
}

const round = (value) => Math.round(value * 10) / 10;
const result = {
  first_visit_ms: round(median(first)),
  return_visit_ms: round(median(again)),
  one_paint: loads.every((entry) => entry.onePaint) ? 1 : 0,
  same_mail: loads.every((entry) => entry.rows > 0 && entry.top === loads[0].top) ? 1 : 0,
  page_errors: loads.reduce((sum, entry) => sum + entry.errors.length, 0),
  first_visit_bytes: firstBytes,
  first_visit_requests: firstRequests,
  first_visit_samples: first.map(round),
  return_visit_samples: again.map(round),
};
for (const [phase, values] of Object.entries(phases)) result["phase_" + phase + "_ms"] = round(median(values));
console.log(JSON.stringify(result));
