// The Assistant's chats and turns as records: history, navigation, a question,
// two tabs, and a question asked offline. Run against a Rails-served or
// compiled demo with a seeded sync server.
import assert from "node:assert/strict";
import { chromium } from "../bench/env.mjs";

const origin = process.argv[2];
const browser = await chromium.launch({ channel: "chrome" });
try {
  const context = await browser.newContext({ viewport: { width: 1440, height: 840 } });
  // No model in this browser: every question is Rails' to answer.
  await context.addInitScript(() => Object.defineProperty(window, "LanguageModel", { value: undefined }));
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.goto(new URL("/assistant", origin).href);
  const chats = page.getByRole("navigation", { name: "Conversations" });
  await chats.getByRole("link", { name: "Keep my place in chat" }).waitFor();
  const compiled = await page.evaluate(() => !!window.__spinel?.worker);
  const turns = page.locator(".relay-turn");
  const title = name => page.locator(".relay-bar strong").filter({ hasText: name }).waitFor();
  const scroll = page.getByRole("region", { name: "Conversation messages" });
  const gap = () => scroll.evaluate(el => el.scrollHeight - el.clientHeight - el.scrollTop);
  const input = page.getByRole("textbox", { name: "Message" });
  const ask = async prompt => { await input.fill(prompt); await input.press("Enter"); };
  assert.equal(await turns.count(), 8);
  assert.ok(await gap() < 2);
  assert.equal(await chats.getByRole("link", { name: "Keep my place in chat" }).getAttribute("aria-current"), "page");

  // Earlier turns come from records, a page at a time, and the reader stays where they were.
  const composer = await page.locator(".relay-composer").boundingBox();
  let pages = 0;
  while (await page.getByRole("link", { name: "Load earlier messages" }).isVisible()) {
    const count = await turns.count();
    const anchor = await scroll.evaluate(el => {
      el.scrollTop = 0;
      const first = el.querySelector(".relay-turn");
      return { id: first.id, y: first.getBoundingClientRect().top };
    });
    await page.waitForFunction(n => document.querySelectorAll(".relay-turn").length > n, count);
    const added = await turns.count() - count;
    assert.ok(added > 0 && added <= 8);
    const y = await page.locator(`[id="${anchor.id}"]`).evaluate(el => el.getBoundingClientRect().top);
    assert.ok(Math.abs(y - anchor.y) <= 1, "earlier turns moved the reader");
    assert.ok(++pages <= 6);
  }
  assert.equal(await turns.count(), 45);
  assert.equal(pages, 5);
  assert.deepEqual(await page.locator(".relay-composer").boundingBox(), composer);
  await page.getByRole("button", { name: /Latest/ }).click();
  assert.ok(await gap() < 2);

  // Opening another chat swaps the page's live parts; a compiled page needs no network for it.
  if (compiled) await context.setOffline(true);
  for (const [name, expected] of [["Trace a missing email", 40], ["Build an offline Todo", 39]]) {
    await chats.getByRole("link", { name, exact: true }).click();
    await title(name);
    assert.equal(await turns.count(), 8);
    assert.ok(await gap() < 2);
    assert.equal(await chats.getByRole("link", { name, exact: true }).getAttribute("aria-current"), "page");
    while (await page.getByRole("link", { name: "Load earlier messages" }).isVisible()) {
      const prior = await turns.count();
      await scroll.evaluate(el => { el.scrollTop = 0; });
      await page.waitForFunction(n => document.querySelectorAll(".relay-turn").length > n, prior);
    }
    assert.equal(await turns.count(), expected);
  }
  if (compiled) await context.setOffline(false);
  await page.goBack();
  await title("Trace a missing email");

  // A question is a record, and so is Rails' answer: both are there after a reload.
  await page.getByRole("button", { name: "New chat", exact: true }).click();
  await title("New chat");
  await page.getByRole("button", { name: "Inspect my workspace" }).click();
  await title("Inspect my workspace");
  await page.locator(".relay-response").getByText(/server workspace has \d+ todos/i).waitFor();
  assert.equal(await turns.last().locator(".relay-author").textContent(), "Demo guide");
  assert.equal(await input.inputValue(), "");
  const chat = page.url();
  assert.match(chat, /\?chat=[0-9a-f-]{36}/);
  assert.equal(await chats.getByRole("link", { name: "Inspect my workspace" }).first().getAttribute("aria-current"), "page");
  await page.reload();
  await page.locator(".relay-response").getByText(/server workspace has \d+ todos/i).waitFor();
  assert.equal(await turns.count(), 1);

  // Another tab draws the same records, and hears of the next turn.
  const peer = await context.newPage();
  await peer.goto(chat);
  await peer.locator(".relay-response").getByText(/server workspace has \d+ todos/i).waitFor();
  await ask("Show a Rails query");
  await page.locator(".relay-response code").waitFor();
  if (compiled) await peer.locator(".relay-response code").waitFor();
  await context.grantPermissions(["clipboard-read", "clipboard-write"], { origin: new URL(origin).origin });
  await page.getByRole("button", { name: "Copy code" }).click();
  await page.getByRole("button", { name: "Copied" }).waitFor();
  assert.match(await page.evaluate(() => navigator.clipboard.readText()), /pluck\(:title\)/);

  await page.getByRole("link", { name: "View source", exact: true }).click();
  await page.locator("#source-drawer[open] .source-path").filter({ hasText: "assistant_turn.rb" }).waitFor();
  assert.equal(page.url(), chat);

  // Asked offline, a question waits in the outbox. Rails answers it once it syncs.
  if (compiled) {
    await page.getByLabel("Offline", { exact: true }).check();
    await page.getByRole("status").filter({ hasText: "Rails answers once it syncs" }).waitFor();
    await page.getByRole("button", { name: "New chat", exact: true }).click();
    await title("New chat");
    await ask("Explain offline sync");
    await title("Explain offline sync");
    await turns.last().getByText("Waiting for Rails…").waitFor();
    await turns.last().getByText("Waiting to sync").waitFor();
    await page.reload();
    await turns.last().getByText("Waiting to sync").waitFor();
    assert.equal(await turns.count(), 1);
    await page.getByLabel("Offline", { exact: true }).uncheck();
    await turns.last().getByText(/worker sends pending mutations/).waitFor();
    assert.equal(await turns.last().getByText("Waiting to sync").count(), 0);
    await peer.getByRole("navigation", { name: "Conversations" }).getByRole("link", { name: "Explain offline sync" }).first().waitFor();
  }

  await page.setViewportSize({ width: 390, height: 844 });
  await page.reload();
  await page.getByRole("button", { name: "Toggle chat history" }).click();
  await chats.getByRole("link", { name: "Inspect my workspace" }).first().click();
  await page.locator(".relay-response code").waitFor();
  assert.ok(await page.locator(".relay-sidebar").isHidden());
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  assert.deepEqual(errors, []);
  console.log("Example histories, the reader's place, chat navigation, a question and its reply as records, two tabs, " +
    (compiled ? "a question asked offline, " : "") + "copy and mobile navigation passed.");
} finally { await browser.close(); }
