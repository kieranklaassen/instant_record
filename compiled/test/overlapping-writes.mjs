// Run against a seeded test demo: node compiled/test/overlapping-writes.mjs <demo-url>
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { chromium } from "../bench/env.mjs";

const url = new URL("/todo", process.argv[2]).href;
const browser = await chromium.launch({ channel: "chrome" });

async function openTodo(context = browser) {
  const page = await context.newPage();
  await page.goto(url);
  await page.waitForFunction(() => window.Stimulus?.controllers.some(c => c.identifier === "issues"));
  return page;
}
function issue(page, title) {
  return page.locator("ul.issues li").filter({ has: page.getByText(title, { exact: true }) });
}
async function add(page, title) {
  const form = page.locator("form.todo-form");
  await form.locator("input[type=text]").fill(title);
  await form.evaluate(f => f.requestSubmit());
}

try {
  for (const scenario of ["accepted", "rejected", "other tab"]) {
    const rejected = scenario === "rejected";
    const context = await browser.newContext();
    const page = await openTodo(context);
    const editor = scenario === "other tab" ? await openTodo(context) : page;
    if (editor !== page) await editor.locator("[data-inspector-target=offline]").check();
    const worker = page.workers()[0];
    // Let Rails finish the first mutation, but withhold its reply from the reactor.
    await worker.evaluate(() => {
      const original = self.fetch.bind(self);
      let signal;
      self.ackReceived = new Promise(resolve => { signal = resolve; });
      const gate = new Promise(resolve => { self.releaseAck = resolve; });
      self.fetch = async (url, init) => {
        const response = await original(url, init);
        if (init?.method === "POST" && String(url).endsWith("/mutations")) {
          self.fetch = original;
          signal();
          await gate;
        }
        return response;
      };
    });
    const title = "overlapping edit " + randomUUID();
    await add(page, rejected ? "reject me" : title);
    await worker.evaluate(() => Promise.race([
      self.ackReceived,
      new Promise((_, reject) => setTimeout(() => reject(Error("Missing write acknowledgment")), 5000)),
    ]));
    try {
      if (rejected) {
        await add(page, title);
        await issue(page, title).waitFor({ timeout: 2000 });
      } else {
        await issue(editor, title).locator("input[type=checkbox]").click({ timeout: 2000 });
        await issue(editor, title).and(editor.locator("li.done")).waitFor({ timeout: 2000 });
      }
    } finally {
      await worker.evaluate(() => self.releaseAck());
    }
    await page.waitForFunction(() => document.querySelector("#pending-count")?.textContent.trim().startsWith("0 "));
    const fresh = await openTodo(); // Different browser context, bootstrapped from Rails.
    assert.equal(await issue(fresh, title).count(), 1);
    assert.equal(await issue(fresh, title).locator("input[type=checkbox]").isChecked(), !rejected);
    if (rejected) assert.equal(await issue(fresh, "reject me").count(), 0);
    await fresh.close();
    await context.close();
  }
  console.log("Overlapping edits survived accepted and rejected acknowledgments.");
  const context = await browser.newContext();
  const first = await openTodo(context);
  await first.locator("[data-inspector-target=offline]").check();
  // Restore offline mode before bootstrap, including when every original tab is gone.
  await context.addInitScript(() => sessionStorage.setItem("instant_record.inspector", '{"offline":true}'));
  const second = await openTodo(context);
  const titles = [randomUUID(), randomUUID()];
  await Promise.all([first, second].map(async (page, i) => {
    await add(page, titles[i]);
    await issue(page, titles[i]).waitFor();
  }));
  await Promise.all([first.close(), second.close()]);
  const restored = await openTodo(context);
  for (const title of titles) assert.equal(await issue(restored, title).count(), 1, "Both confirmed offline writes must survive");
  const peer = await openTodo();
  for (const title of titles) assert.equal(await issue(peer, title).count(), 0, "Offline writes must still be local");
  await restored.locator("[data-inspector-target=offline]").uncheck();
  await restored.waitForFunction(() => document.querySelector("#pending-count")?.textContent.trim().startsWith("0 "));
  await peer.reload();
  for (const title of titles) {
    await issue(peer, title).waitFor();
    assert.equal(await issue(peer, title).count(), 1);
  }
  await context.close();
  await peer.close();
  console.log("Both offline tabs' writes survived closure, restored locally and synced to Rails exactly once.");
} finally {
  await browser.close();
}
