// Run after seeding the Rails demo, passing the compiled and Rails origins.
import assert from "node:assert/strict";
import { performance } from "node:perf_hooks";
import { chromium } from "../bench/env.mjs";

const [site, rails] = process.argv.slice(2);
const sync = new URL("/email/sync/maya/support/", rails);
const seen = new Set();
let route = "bootstrap", pages = 0, maxRoots = 0, bootstrapBytes;
do {
  const response = await fetch(new URL(route, sync));
  assert.equal(response.status, 200);
  const text = await response.text();
  if (!pages) bootstrapBytes = Buffer.byteLength(text);
  const batch = JSON.parse(text);
  const messages = batch.records.filter(row => row.attributes.kind === "message");
  maxRoots = Math.max(maxRoots, messages.length);
  assert.ok(messages.length <= 50);
  for (const row of messages) {
    assert.equal(row.attributes.mailbox_id, "support");
    assert.ok(!seen.has(row.id), "duplicate keyset boundary " + row.id);
    seen.add(row.id);
  }
  pages++;
  if (batch.has_more === false || !messages.length) break;
  const last = messages.at(-1);
  route = "records?" + new URLSearchParams({ type: "MailEntry", before_id: last.id, before_created_at: last.attributes.created_at });
} while (true);
assert.ok(seen.size >= 10000);
const browser = await chromium.launch({ channel: "chrome" });
try {
  const viewport = process.argv.includes("--mobile") ? { width: 390, height: 844 } : { width: 1280, height: 800 };
  const page = await browser.newPage({ viewport });
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  page.on("crash", () => errors.push("renderer crashed"));
  const started = performance.now();
  await page.goto(new URL("/email", site).href);
  const rows = page.locator(".mail-row");
  await rows.nth(49).waitFor();
  const firstPaintMs = Math.round(performance.now() - started);
  const list = page.locator(".mail-list");
  const ids = new Set(await rows.evaluateAll(nodes => nodes.map(node => node.dataset.id)));
  const entireInbox = process.argv.includes("--all");
  const browserPages = entireInbox ? pages : 5;
  const newest = await rows.first().getAttribute("data-id");
  const reader = await page.locator(".mail-reader").getAttribute("data-thread");
  const initialUrl = page.url();
  for (let n = 0; n < browserPages - 1; n++) {
    const anchor = await list.evaluate(el => {
      el.scrollTop = el.scrollHeight;
      const last = el.querySelector(".mail-row:last-of-type");
      return { id: last.dataset.id, y: last.getBoundingClientRect().top };
    });
    await page.waitForFunction(id => document.querySelector(".mail-row:last-of-type").dataset.id !== id, anchor.id);
    const position = await page.locator(`.mail-row[data-id="${anchor.id}"]`).evaluate(el => el.getBoundingClientRect().top);
    assert.ok(Math.abs(position - anchor.y) <= 2, "scroll jumped while appending older mail");
    const mounted = await rows.evaluateAll(nodes => nodes.map(node => node.dataset.id));
    assert.ok(mounted.length <= 150);
    assert.equal(new Set(mounted).size, mounted.length);
    for (const id of mounted) ids.add(id);
    assert.equal(ids.size, Math.min(seen.size, (n + 2) * 50));
    assert.equal(page.url(), initialUrl);
    assert.equal(await page.locator(".mail-reader").getAttribute("data-thread"), reader);
  }
  if (entireInbox) assert.deepEqual(ids, seen);
  const href = await rows.nth(124).getAttribute("href");
  const subject = await rows.nth(124).locator("strong").textContent();
  const incoming = process.argv.includes("--incoming");
  let incomingId;
  if (incoming) {
    const oldTop = await list.evaluate(el => el.scrollTop);
    const response = await page.request.post(new URL("incoming", sync).href);
    assert.equal(response.status(), 201);
    incomingId = (await response.json()).id;
    if (await page.evaluate(() => !!window.__spinel?.worker)) {
      await page.waitForFunction(async id => {
        const url = new URL("/email", location.href);
        url.searchParams.set("fragment", "1");
        return (await (await fetch(url)).text()).includes(id);
      }, incomingId, { polling: 300 });
    }
    assert.equal(await list.evaluate(el => el.scrollTop), oldTop);
  }
  for (let n = 0; n < (incoming ? 3 : 2); n++) {
    const prior = await rows.first().getAttribute("data-id");
    await list.evaluate(el => { el.scrollTop = 0; el.dispatchEvent(new Event("scroll")); });
    await page.waitForFunction(id => document.querySelector(".mail-row").dataset.id !== id, prior);
  }
  if (incoming) {
    assert.equal(await rows.first().getAttribute("data-id"), incomingId);
    assert.equal(await rows.nth(1).getAttribute("data-id"), newest);
  } else if (!entireInbox) assert.equal(await rows.first().getAttribute("data-id"), newest);
  const fresh = await browser.newPage();
  await fresh.goto(new URL(href, site).href);
  await fresh.getByRole("heading", { name: subject, exact: true }).waitFor();
  assert.deepEqual(errors, []);
  console.log(JSON.stringify({ openMessages: seen.size, pages, maxRoots, bootstrapBytes, browserDistinctRows: ids.size, firstPaintMs }));
} finally { await browser.close(); }
