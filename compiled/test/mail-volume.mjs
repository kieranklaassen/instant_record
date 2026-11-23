// Run after seeding the Rails demo, passing the compiled and Rails origins.
import assert from "node:assert/strict";
import { performance } from "node:perf_hooks";
import { chromium } from "../bench/env.mjs";

const [site, rails] = process.argv.slice(2);
const sync = new URL("/instant_record/", rails);
const headers = { "X-Instant-Record-Partition": "mailbox_id:support", "X-Instant-Record-Member": "maya" };
const seen = new Set();
let route = "bootstrap", pages = 0, maxRoots = 0, bootstrapBytes;
do {
  const response = await fetch(new URL(route, sync), { headers });
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
  // The list is virtual: only the rows near the viewport are in the document,
  // so the walk scrolls and counts the distinct rows it passes.
  const rows = page.locator(".mail-row");
  await rows.first().waitFor();
  const firstPaintMs = Math.round(performance.now() - started);
  const scroller = page.locator(".mail-list [data-virtuoso-scroller]");
  const mountedIds = () => rows.evaluateAll(nodes => nodes.map(node => node.dataset.id));
  const ids = new Set(await mountedIds());
  const entireInbox = process.argv.includes("--all");
  const wanted = entireInbox ? seen.size : 250;
  const newest = await rows.first().getAttribute("data-id");
  const open = () => page.locator(".mail-reader h2").first().textContent();
  const reader = await open();
  let deep, stalled = 0;
  while (ids.size < wanted && stalled < 40) {
    const before = ids.size;
    const anchor = await scroller.evaluate(el => {
      el.scrollTop = el.scrollHeight;
      const last = [...el.querySelectorAll(".mail-row")].at(-1);
      return { id: last.dataset.id, y: last.getBoundingClientRect().top, height: el.scrollHeight };
    });
    // Older mail arrives below: the list grows and the row that was last stays where it was.
    await page.waitForFunction(height => document.querySelector(".mail-list [data-virtuoso-scroller]").scrollHeight > height, anchor.height, { timeout: 5000 }).catch(() => {});
    const kept = page.locator(`.mail-row[data-id="${anchor.id}"]`);
    if (await kept.count()) {
      const position = await kept.evaluate(el => el.getBoundingClientRect().top);
      assert.ok(Math.abs(position - anchor.y) <= 2, "scroll jumped while appending older mail");
    }
    const mounted = await mountedIds();
    assert.ok(mounted.length <= 150, "the virtual list mounted " + mounted.length + " rows");
    assert.equal(new Set(mounted).size, mounted.length);
    for (const id of mounted) ids.add(id);
    if (!deep && ids.size >= 125) deep = { href: await rows.last().locator("a").getAttribute("href"), subject: await rows.last().locator("strong").textContent() };
    assert.equal(await open(), reader);
    stalled = ids.size === before ? stalled + 1 : 0;
  }
  assert.ok(ids.size >= wanted, "walked " + ids.size + " of " + wanted + " rows");
  for (const id of ids) assert.ok(seen.has(id), "a row the server never listed: " + id);
  const { href, subject } = deep;
  const incoming = process.argv.includes("--incoming");
  if (incoming) {
    // A reader deep in the list keeps their place: the row they are on stays put.
    const place = () => rows.nth(3).evaluate(el => ({ id: el.dataset.id, y: el.getBoundingClientRect().top }));
    const held = await place();
    const response = await page.request.post(new URL("/email/incoming?member=maya&inbox=support", rails).href);
    assert.equal(response.status(), 201);
    const incomingId = (await response.json()).id;
    await page.waitForTimeout(3000);
    const now = await page.locator(`.mail-row[data-id="${held.id}"]`).evaluate(el => el.getBoundingClientRect().top);
    assert.ok(Math.abs(now - held.y) <= 2, "new mail moved a reader deep in the list by " + (now - held.y));
    await scroller.evaluate(el => { el.scrollTop = 0; });
    await page.locator(`.mail-row[data-id="${incomingId}"]`).waitFor();
    assert.equal(await rows.first().getAttribute("data-id"), incomingId);
    assert.equal(await rows.nth(1).getAttribute("data-id"), newest);
  } else {
    await scroller.evaluate(el => { el.scrollTop = 0; });
    await page.locator(`.mail-row[data-id="${newest}"]`).waitFor();
    assert.equal(await rows.first().getAttribute("data-id"), newest);
  }
  // A browser that has never scrolled this far opens the same conversation.
  const fresh = await browser.newPage();
  await fresh.goto(new URL(href, site).href);
  await fresh.getByRole("heading", { name: subject, exact: true }).waitFor();
  assert.deepEqual(errors, []);
  console.log(JSON.stringify({ openMessages: seen.size, pages, maxRoots, bootstrapBytes, browserDistinctRows: ids.size, firstPaintMs }));
} finally { await browser.close(); }
