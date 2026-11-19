// The Assistant's engines: Rails, the browser's own model, and the switch between them.
// Either one answers by writing its reply onto the turn's record.
// Run against a Rails-served or compiled demo. A browser under test may offer
// LanguageModel but has no model to run, so a stand-in is installed before the page loads.
import assert from "node:assert/strict";
import { chromium } from "../bench/env.mjs";

const origin = process.argv[2];

function fakeModel(state) {
  if (!state) return Object.defineProperty(window, "LanguageModel", { value: undefined });
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
  window.__localCalls = [];
  window.LanguageModel = {
    state,
    async availability() { return this.state; },
    async create(options = {}) {
      // A small context, as the real model has: turns that don't fit are refused.
      const turns = (options.initialPrompts || []).filter(message => message.role !== "system");
      if (turns.reduce((size, message) => size + message.content.length, 0) > 2500) throw new DOMException("Too large", "QuotaExceededError");
      const download = new EventTarget();
      options.monitor?.(download);
      if (this.state !== "available") {
        for (const loaded of [0.25, 0.75, 1]) {
          await sleep(150);
          download.dispatchEvent(Object.assign(new Event("downloadprogress"), { loaded }));
        }
        this.state = "available";
      }
      return {
        destroy() {},
        promptStreaming(prompt, { signal } = {}) {
          window.__localCalls.push({ prompt, turns: turns.length });
          const text = /long/.test(prompt) ? "word ".repeat(600) : `On-device answer to: ${prompt}`;
          const words = text.match(/\S+\s*/g);
          return new ReadableStream({
            async start(stream) {
              for (const word of words) {
                if (signal?.aborted) return stream.error(new DOMException("Aborted", "AbortError"));
                stream.enqueue(word);
                await sleep(/slow/.test(prompt) ? 150 : 2);
              }
              stream.close();
            }
          });
        }
      };
    }
  };
}

const providerCalls = [];
const browser = await chromium.launch({ channel: "chrome" });
try {
  const open = async (state, path = "/assistant") => {
    const context = await browser.newContext({ viewport: { width: 1440, height: 840 } });
    await context.addInitScript(fakeModel, state);
    // A model provider is only ever asked by Rails: the browser must never call one.
    context.on("request", request => {
      const url = new URL(request.url());
      if (/anthropic|openai|googleapis\.com\/v1|generativelanguage/.test(url.host + url.pathname)) providerCalls.push(request.url());
    });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.goto(new URL(path, origin).href);
    await page.getByRole("link", { name: "Keep my place in chat" }).waitFor();
    return { context, page, errors };
  };
  const helpers = page => {
    const input = page.getByRole("textbox", { name: "Message" });
    const status = text => page.getByRole("status").filter({ hasText: text }).waitFor();
    const turns = page.locator(".relay-turn");
    return {
      input, status, turns,
      engine: name => page.locator(".relay-engine label").filter({ hasText: name }).click(),
      author: () => turns.last().locator(".relay-author").textContent(),
      idle: () => page.getByRole("button", { name: "Stop", exact: true }).waitFor({ state: "hidden" }),
      ask: async prompt => { await input.fill(prompt); await input.press("Enter"); },
      newChat: async () => {
        await page.getByRole("button", { name: "New chat", exact: true }).click();
        await page.locator(".relay-bar strong").filter({ hasText: "New chat" }).waitFor();
      }
    };
  };

  // A browser with a model ready.
  {
    const { context, page, errors } = await open("available");
    const { input, status, engine, turns, author, idle, ask, newChat } = helpers(page);
    const compiled = await page.evaluate(() => !!window.__spinel?.worker);
    const local = () => page.evaluate(() => window.__localCalls);
    const offline = page.getByLabel("Offline", { exact: true });

    // Auto, online: Rails answers, in a job, and the reply arrives as a record.
    await status("Replies come from Rails");
    await newChat();
    await ask("Explain offline sync");
    await turns.last().getByText(/worker sends pending mutations/).waitFor();
    assert.equal(await author(), "Demo guide");
    assert.deepEqual(await local(), []);

    // Auto, offline: the browser's model answers, with the earlier turn as context, and its reply is saved.
    await offline.check();
    await status("Replies come from the model in this browser");
    await ask("What is an outbox?");
    await turns.last().getByText("On-device answer to: What is an outbox?").waitFor();
    await idle();
    assert.equal(await author(), "On-device model");
    assert.deepEqual(await local(), [{ prompt: "What is an outbox?", turns: 2 }]);
    assert.equal(await input.inputValue(), "");
    const chat = page.url();
    await page.reload();
    await turns.last().getByText("On-device answer to: What is an outbox?").waitFor();
    assert.equal(await author(), "On-device model");
    assert.equal(await turns.count(), 2);

    // Stop ends a local reply where it stands, and what was said is kept.
    await status("Replies come from the model in this browser");
    await ask("slow answer please");
    await turns.last().getByText(/On-device answer/).waitFor();
    await page.getByRole("button", { name: "Stop", exact: true }).click();
    await turns.last().getByText(/Reply stopped/).waitFor();
    await idle();
    await page.reload();
    await turns.last().getByText(/Reply stopped/).waitFor();

    // A long local reply is saved whole, and the next question forgets the oldest turns to fit.
    await status("Replies come from the model in this browser");
    await ask("a long answer " + "x".repeat(1985) + "😀😀");
    await idle();
    await page.waitForFunction(() => document.querySelector(".relay-turn:last-child").dataset.pending === "false");
    assert.ok((await turns.last().locator(".relay-response").textContent()).length > 2000);
    await ask("And after that?");
    await turns.last().getByText("On-device answer to: And after that?").waitFor();
    await idle();
    assert.ok((await local()).at(-1).turns < 8);

    // Server, chosen while offline: the question is saved, and Rails answers once it can.
    await engine("Server");
    await status("Rails answers once it syncs");
    assert.equal(await page.getByRole("button", { name: "Send message" }).isDisabled(), false);
    const before = (await local()).length;
    await ask("Show a Rails query");
    if (compiled) await turns.last().getByText("Waiting for Rails…").waitFor();
    await offline.uncheck();
    await status("Replies come from Rails");
    await turns.last().locator(".relay-response code").waitFor();
    assert.equal((await local()).length, before);

    // On-device while online, and the choice survives a reload.
    await engine("On-device");
    await status("Replies come from the model in this browser");
    await ask("Stay local");
    await turns.last().getByText("On-device answer to: Stay local").waitFor();
    await idle();
    await page.reload();
    await status("Replies come from the model in this browser");
    assert.equal(await page.getByRole("radio", { name: "On-device" }).isChecked(), true);
    await engine("Auto");

    // A browser that was never here gets the on-device replies from Rails, like any record.
    const other = await open(null, new URL(chat).pathname + new URL(chat).search);
    await other.page.locator(".relay-turn").filter({ hasText: "On-device answer to: Stay local" }).waitFor();
    assert.equal(await other.page.locator(".relay-turn").filter({ hasText: "On-device answer to: What is an outbox?" }).locator(".relay-author").textContent(), "On-device model");
    assert.deepEqual(other.errors, []);
    await other.context.close();
    assert.deepEqual(errors, []);
    await context.close();
  }

  // A browser with no model: On-device is off, and Rails is asked.
  {
    const { context, page, errors } = await open(null);
    const { status, turns, ask, newChat } = helpers(page);
    await status("Replies come from Rails");
    assert.equal(await page.getByRole("radio", { name: "On-device" }).isDisabled(), true);
    await newChat();
    await ask("Show a Rails query");
    await turns.last().locator(".relay-response code").waitFor();
    assert.deepEqual(errors, []);
    await context.close();
  }

  // A browser whose model must be downloaded: choosing On-device fetches it.
  {
    const { context, page, errors } = await open("downloadable");
    const { status, engine, turns, idle, ask, newChat } = helpers(page);
    await status("Replies come from Rails");
    assert.equal(await page.getByRole("radio", { name: "On-device" }).isDisabled(), false);
    await engine("On-device");
    await status("Downloading the on-device model");
    await status("Replies come from the model in this browser");
    await newChat();
    await ask("Ready?");
    await turns.last().getByText("On-device answer to: Ready?").waitFor();
    await idle();
    await engine("Auto");
    assert.deepEqual(errors, []);
    await context.close();
  }
  assert.deepEqual(providerCalls, []);
  console.log("Rails' replies and the browser model's replies as records, the engine switch, stop, a small context, a question saved offline, no model and download passed.");
} finally { await browser.close(); }
