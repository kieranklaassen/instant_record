// Run against a compiled demo with a seeded sync server.
import assert from "node:assert/strict";
import { chromium } from "../bench/env.mjs";

const origin = process.argv[2];
const browser = await chromium.launch({ channel: "chrome" });
try {
  const context = await browser.newContext({ viewport: { width: 1440, height: 840 } });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.goto(new URL("/assistant", origin).href);
  await page.getByRole("navigation", { name: "Conversations" }).getByRole("link", { name: "Keep my place in chat" }).waitFor();
  assert.equal(await page.locator(".relay-answer").count(), 8);
  const scroll = page.getByRole("region", { name: "Conversation messages" });
  const gap = () => scroll.evaluate(el => el.scrollHeight - el.clientHeight - el.scrollTop);
  assert.ok(await gap() < 2);
  const composer = await page.locator(".relay-composer").boundingBox();
  const inspector = await page.locator("#inspector").boundingBox();
  const latest = page.getByRole("button", { name: /Latest/ });
  let pages = 0;
  while (await page.getByRole("button", { name: "Load earlier messages" }).isVisible()) {
    const count = await page.locator(".relay-answer").count();
    const anchor = await scroll.evaluate(el => {
      el.scrollTop = 0;
      const first = el.querySelector("[data-turn]");
      return { id: first.dataset.turn, y: first.getBoundingClientRect().top };
    });
    await page.waitForFunction(n => document.querySelectorAll(".relay-answer").length > n, count);
    const added = await page.locator(".relay-answer").count() - count;
    assert.ok(added > 0 && added <= 8);
    const y = await page.locator(`[data-turn="${anchor.id}"]`).evaluate(el => el.getBoundingClientRect().top);
    assert.ok(Math.abs(y - anchor.y) <= 1, "history prepend moved the reader");
    pages++;
    assert.ok(pages <= 6);
  }
  assert.equal(await page.locator(".relay-answer").count(), 45);
  assert.equal(pages, 5);
  assert.deepEqual(await page.locator(".relay-composer").boundingBox(), composer);
  assert.deepEqual(await page.locator("#inspector").boundingBox(), inspector);
  const position = await scroll.evaluate(el => el.scrollTop);
  const compiled = await page.evaluate(() => !!window.__spinel?.worker);
  if (compiled) await context.setOffline(true);
  for (const [name, expected] of [["Trace a missing email", 40], ["Build an offline Todo", 39]]) {
    await page.getByRole("link", { name, exact: true }).click();
    await page.locator(".relay-bar strong").filter({ hasText: name }).waitFor();
    assert.equal(await page.locator(".relay-answer").count(), Math.min(8, expected - 32));
    while (await page.getByRole("button", { name: "Load earlier messages" }).isVisible()) {
      const prior = await page.locator(".relay-answer").count();
      await scroll.evaluate(el => { el.scrollTop = 0; });
      await page.waitForFunction(n => document.querySelectorAll(".relay-answer").length > n, prior);
    }
    assert.equal(await page.locator(".relay-answer").count(), expected);
  }
  if (compiled) await context.setOffline(false);
  await page.getByRole("link", { name: "Keep my place in chat" }).click();
  // Latest is already showing in the conversation being left: wait for the one being opened.
  await page.locator(".relay-bar strong").filter({ hasText: "Keep my place in chat" }).waitFor();
  await latest.waitFor();
  assert.equal(await scroll.evaluate(el => el.scrollTop), position);
  await latest.click();
  assert.ok(await gap() < 2);
  await page.getByRole("textbox", { name: "Message" }).fill("Explain offline sync");
  await page.getByRole("button", { name: "Send message" }).click();
  await page.locator(".relay-answer").last().getByText(/worker sends pending mutations/).waitFor();
  await page.getByRole("button", { name: "Stop", exact: true }).waitFor({ state: "hidden" });
  await page.reload();
  await page.locator(".relay-answer").last().getByText(/worker sends pending mutations/).waitFor();
  assert.equal(await page.locator(".relay-answer").count(), 8);
  assert.equal(await page.getByRole("link", { name: "Keep my place in chat" }).count(), 1);
  await page.getByRole("button", { name: "New chat", exact: true }).click();
  await page.getByRole("button", { name: "Inspect my workspace" }).click();
  await page.locator(".relay-response").getByText(/server workspace has \d+ todos/i).waitFor();
  await page.getByRole("button", { name: "Stop", exact: true }).waitFor({ state: "hidden" });
  const original = page.url();
  await page.getByRole("link", { name: "View source", exact: true }).click();
  await page.locator("#source-drawer[open] .source-path").filter({ hasText: "assistant_chat_controller.js" }).waitFor();
  assert.equal(page.url(), original);
  const peer = await context.newPage();
  await peer.goto(original);
  await peer.locator(".relay-response").getByText(/server workspace has \d+ todos/i).waitFor();

  await page.getByLabel("Offline", { exact: true }).check();
  await page.getByRole("button", { name: "New chat", exact: true }).click();
  const composerInput = page.getByRole("textbox", { name: "Message" });
  let offlinePosts = 0;
  const countPost = request => { if (request.url().includes("/assistant/replies") && request.method() === "POST") offlinePosts++; };
  context.on("request", countPost);
  await composerInput.fill("Show a Rails query");
  await composerInput.press("Enter");
  assert.equal(await page.getByRole("button", { name: "Send message" }).isDisabled(), true);
  assert.equal(await page.locator(".relay-answer").count(), 0);
  await page.reload();
  await page.getByRole("status").filter({ hasText: "Reconnect to send" }).waitFor();
  assert.equal(await composerInput.inputValue(), "Show a Rails query");
  assert.equal(offlinePosts, 0);
  await page.getByLabel("Offline", { exact: true }).uncheck();
  assert.equal(await page.locator(".relay-answer").count(), 0);
  const posted = context.waitForEvent("response", response => response.url().includes("/assistant/replies") && response.request().method() === "POST");
  await composerInput.press("Enter");
  assert.equal((await posted).status(), 200);
  context.off("request", countPost);
  await page.waitForFunction(() => document.querySelector(".relay-response code")?.textContent.includes(".pluck(:title)"));
  await page.getByRole("button", { name: "Stop", exact: true }).waitFor({ state: "hidden" });
  await page.reload();
  await page.locator(".relay-response code").waitFor();
  await context.grantPermissions(["clipboard-read", "clipboard-write"], { origin: new URL(origin).origin });
  await page.getByRole("button", { name: "Copy code" }).click();
  await page.getByRole("button", { name: "Copied" }).waitFor();
  assert.match(await page.evaluate(() => navigator.clipboard.readText()), /pluck\(:title\)/);
  const input = page.getByRole("textbox", { name: "Message" });
  await input.fill("Explain offline sync");
  await input.press("Enter");
  await page.locator(".relay-answer").last().getByText(/A Todo write/).waitFor();
  await page.getByRole("button", { name: "Stop", exact: true }).click();
  await page.locator(".relay-response").getByText(/Reply stopped/).waitFor();
  await peer.getByRole("link", { name: "Show a Rails query" }).click();
  await peer.locator(".relay-response").getByText(/Reply stopped/).waitFor();
  await page.getByRole("link", { name: "Inspect my workspace" }).click();
  await page.locator(".relay-response").getByText(/server workspace has/i).waitFor();
  assert.equal(await page.locator(".relay-answer").count(), 1);
  await context.route("**/assistant/replies*", route => route.abort("failed"));
  await input.fill("test unreachable server");
  await input.press("Enter");
  await page.getByRole("status").filter({hasText: "ready to retry"}).waitFor();
  assert.equal(await input.inputValue(), "test unreachable server");
  assert.equal(await page.locator(".relay-answer").count(), 1);
  await context.unroute("**/assistant/replies*");
  await context.setOffline(true);
  await page.getByRole("status").filter({hasText: "Reconnect to send"}).waitFor();
  assert.equal(await input.inputValue(), "test unreachable server");
  assert.equal(await page.getByRole("button", { name: "Send message" }).isDisabled(), true);
  await context.setOffline(false);
  const sidebar = await page.locator("#inspector").boundingBox();
  assert.ok(sidebar.x === 0 && sidebar.width <= (await page.locator(".relay").boundingBox()).x);

  await page.setViewportSize({ width: 390, height: 844 });
  await page.reload();
  await page.getByRole("button", { name: "Toggle chat history" }).click();
  await page.getByRole("link", { name: "Show a Rails query" }).click();
  await page.locator(".relay-response code").waitFor();
  assert.ok(await page.locator(".relay-sidebar").isHidden());
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  assert.deepEqual(errors, []);
  console.log("Example histories, scroll position, follow-ups, workspace query, streaming, stop, offline history, two tabs, inspector and mobile navigation passed.");
} finally { await browser.close(); }
