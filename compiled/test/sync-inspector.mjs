// node compiled/test/sync-inspector.mjs <seeded compiled demo URL>
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { chromium } from "../bench/env.mjs";

const url = new URL("/todo", process.argv[2]).href;
const browser = await chromium.launch({ channel: "chrome" });
const page = await browser.newPage();
const errors = [];
page.on("pageerror", error => errors.push(error.message));
const log = page.locator("[data-inspector-target=log]");
const offline = page.locator("[data-inspector-target=offline]");
const slow = page.locator("[data-inspector-target=slow]");
const title = "inspector " + randomUUID();
const issue = p => p.locator("ul.issues li").filter({ hasText: title });

async function ready(p) {
  await p.waitForFunction(() => ["inspector", "issues"].every(name =>
    window.Stimulus?.controllers.some(c => c.identifier === name)));
}

async function serverCount() {
  const fresh = await browser.newPage(); // Empty IndexedDB, bootstrap from Rails.
  try {
    await fresh.goto(url);
    await ready(fresh);
    return await issue(fresh).count();
  } finally {
    await fresh.close();
  }
}

try {
  await page.goto(url);
  await ready(page);
  await log.getByText("GET /instant_record/bootstrap", { exact: true }).waitFor();
  await log.getByText("GET /todo", { exact: true }).waitFor();
  await page.getByRole("button", { name: "Clear" }).click();
  assert.equal(await log.locator("li").count(), 0);
  const history = await page.evaluate(() => new Promise(resolve => {
    const worker = window.__spinel.worker;
    const receive = ({ data }) => {
      if (data.type !== "instant_record.debug_backlog") return;
      worker.removeEventListener("message", receive);
      resolve(data.entries);
    };
    worker.addEventListener("message", receive);
    worker.postMessage({ type: "instant_record.simulate", settings: { report: true, offline: false, latencyMs: 0 }, backlog: true });
  }));
  assert.equal(history.length, 0, "Clearing the panel must also clear the worker's buffer");

  await offline.check();
  await page.locator('[data-flow="up"][data-broken]').waitFor({ state: "attached" });
  const form = page.locator("form.todo-form");
  await form.locator("input[type=text]").fill(title);
  await form.evaluate(f => f.requestSubmit());
  await issue(page).waitFor();
  await page.locator('[data-flow="local"][data-active]').waitFor({ state: "attached", timeout: 1500 });
  await log.locator('li[data-kind=local]').filter({ hasText: "POST /todo/issues" }).waitFor();
  await log.locator('li[data-status=bad]').filter({ hasText: /mutations[\s\S]*offline/ }).waitFor();
  assert.equal(await serverCount(), 0, "Offline must hold the mutation locally");

  await page.reload();
  await ready(page);
  assert.ok(await offline.isChecked());
  await issue(page).waitFor();
  await log.locator('li[data-status=bad]').filter({ hasText: /mutations[\s\S]*offline/ }).waitFor();
  assert.equal(await serverCount(), 0, "Reload must restore Offline before sync");

  await slow.check();
  await offline.uncheck();
  const started = performance.now();
  await issue(page).locator("input[type=checkbox]").click();
  await issue(page).and(page.locator("li.done")).waitFor({ timeout: 1500 });
  assert.ok(performance.now() - started < 1500, "Slow sync must leave local edits responsive");
  const mutation = log.locator('li[data-kind=sync][data-status=ok]').filter({ hasText: "POST /instant_record/mutations" }).first();
  await mutation.waitFor({ timeout: 10000 });
  assert.match(await mutation.innerText(), /200 · (?:[2-9]\d{3}|\d{5,})ms/);
  await page.waitForFunction(() => document.querySelector("#pending-count")?.textContent.trim().startsWith("0 "));
  assert.equal(await serverCount(), 1);
  await slow.uncheck();
  assert.deepEqual(errors, []);
  console.log("Inspector verified: boot history, Clear, local requests, offline reload, reconnection and two-second Slow sync.");
} finally {
  await browser.close();
}
