// The Assistant's engines: Rails, the browser's own model, and the switch between them.
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

const browser = await chromium.launch({ channel: "chrome" });
try {
  const open = async state => {
    const context = await browser.newContext({ viewport: { width: 1440, height: 840 } });
    await context.addInitScript(fakeModel, state);
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.goto(new URL("/assistant", origin).href);
    await page.getByRole("link", { name: "Keep my place in chat" }).waitFor();
    return { context, page, errors };
  };
  const helpers = page => {
    const input = page.getByRole("textbox", { name: "Message" });
    const status = text => page.getByRole("status").filter({ hasText: text }).waitFor();
    return {
      input, status,
      engine: name => page.locator(".relay-engine label").filter({ hasText: name }).click(),
      answers: () => page.locator(".relay-answer"),
      idle: () => page.getByRole("button", { name: "Stop", exact: true }).waitFor({ state: "hidden" }),
      ask: async prompt => { await input.fill(prompt); await input.press("Enter"); },
      newChat: () => page.getByRole("button", { name: "New chat", exact: true }).click()
    };
  };

  // A browser with a model ready.
  {
    const { context, page, errors } = await open("available");
    const { input, status, engine, answers, idle, ask, newChat } = helpers(page);
    const posts = [];
    context.on("request", request => {
      if (request.url().includes("/assistant/replies") && request.method() === "POST") posts.push(JSON.parse(request.postData()));
    });
    const local = () => page.evaluate(() => window.__localCalls);

    // Auto, online: Rails answers, and the second question carries the first turn.
    await status("Replies come from Rails");
    await newChat();
    await ask("Explain offline sync");
    await answers().last().getByText(/worker sends pending mutations/).waitFor();
    await idle();
    await ask("Show a Rails query");
    await page.locator(".relay-response code").waitFor();
    await idle();
    assert.equal(posts.length, 2);
    assert.deepEqual(posts[0].history, []);
    assert.equal(posts[1].history.length, 1);
    assert.equal(posts[1].history[0][0], "Explain offline sync");
    assert.match(posts[1].history[0][1], /worker sends pending mutations/);
    assert.equal(await answers().last().locator(".relay-author").textContent(), "Demo guide");
    assert.deepEqual(await local(), []);

    // Auto, offline: the browser's model answers, nothing is posted, and the turn is saved.
    await page.getByLabel("Offline", { exact: true }).check();
    await status("Replies come from the model in this browser");
    assert.equal(await page.getByRole("button", { name: "Send message" }).isDisabled(), false);
    await ask("What is an outbox?");
    await answers().last().getByText("On-device answer to: What is an outbox?").waitFor();
    await idle();
    assert.equal(await answers().last().locator(".relay-author").textContent(), "On-device model");
    assert.equal(posts.length, 2);
    assert.deepEqual(await local(), [{ prompt: "What is an outbox?", turns: 4 }]);
    assert.equal(await input.inputValue(), "");
    await page.reload();
    await answers().last().getByText("On-device answer to: What is an outbox?").waitFor();
    assert.equal(await answers().last().locator(".relay-author").textContent(), "On-device model");

    // Stop ends a local reply where it stands.
    await status("Replies come from the model in this browser");
    await ask("slow answer please");
    await answers().last().getByText(/On-device answer/).waitFor();
    await page.getByRole("button", { name: "Stop", exact: true }).click();
    await answers().last().getByText(/Reply stopped/).waitFor();

    // Server while offline cannot answer.
    await engine("Server");
    await status("Reconnect to send");
    assert.equal(await page.getByRole("button", { name: "Send message" }).isDisabled(), true);

    // A long local reply does not stop Rails from answering the next question.
    await engine("Auto");
    await ask("a long answer");
    await idle();
    assert.ok((await answers().last().locator(".relay-response").textContent()).length > 2000);
    // The next local question no longer fits with every earlier turn: the oldest are forgotten.
    await ask("And after that?");
    await answers().last().getByText("On-device answer to: And after that?").waitFor();
    await idle();
    assert.ok((await local()).at(-1).turns < 10);
    await page.getByLabel("Offline", { exact: true }).uncheck();
    await engine("Server");
    await status("Replies come from Rails");
    const posted = context.waitForEvent("response", response => response.url().includes("/assistant/replies") && response.request().method() === "POST");
    await ask("Explain offline sync");
    assert.equal((await posted).status(), 200);
    await idle();
    assert.ok(posts.at(-1).history.every(turn => turn.every(text => text.length <= 2000)));
    assert.ok(posts.at(-1).history.length <= 6);

    // On-device while online: nothing is posted, and the choice survives a reload.
    const before = posts.length;
    await engine("On-device");
    await status("Nothing leaves the device");
    await ask("Stay local");
    await answers().last().getByText("On-device answer to: Stay local").waitFor();
    await idle();
    assert.equal(posts.length, before);
    await page.reload();
    await status("Nothing leaves the device");
    assert.equal(await page.getByRole("radio", { name: "On-device" }).isChecked(), true);

    // Auto, online, Rails out of reach: the browser's model answers instead.
    await engine("Auto");
    await context.route("**/assistant/replies*", route => route.abort("failed"));
    await ask("Is Rails there?");
    await answers().last().getByText("On-device answer to: Is Rails there?").waitFor();
    await idle();
    await context.unroute("**/assistant/replies*");
    assert.deepEqual(errors, []);
    await context.close();
  }

  // A browser with no model: On-device is off, and offline keeps the draft as before.
  {
    const { context, page, errors } = await open(null);
    const { input, status, ask, newChat } = helpers(page);
    await status("Replies come from Rails");
    assert.equal(await page.getByRole("radio", { name: "On-device" }).isDisabled(), true);
    await page.getByLabel("Offline", { exact: true }).check();
    await status("Reconnect to send");
    await newChat();
    await ask("Show a Rails query");
    assert.equal(await page.getByRole("button", { name: "Send message" }).isDisabled(), true);
    assert.equal(await input.inputValue(), "Show a Rails query");
    assert.equal(await page.locator(".relay-answer").count(), 0);
    await page.getByLabel("Offline", { exact: true }).uncheck();
    assert.deepEqual(errors, []);
    await context.close();
  }

  // A browser whose model must be downloaded: choosing On-device fetches it.
  {
    const { context, page, errors } = await open("downloadable");
    const { status, engine, answers, idle, ask, newChat } = helpers(page);
    await status("Replies come from Rails");
    assert.equal(await page.getByRole("radio", { name: "On-device" }).isDisabled(), false);
    await engine("On-device");
    await status("Downloading the on-device model");
    await status("Nothing leaves the device");
    await newChat();
    await ask("Ready?");
    await answers().last().getByText("On-device answer to: Ready?").waitFor();
    await idle();
    assert.deepEqual(errors, []);
    await context.close();
  }
  console.log("Server replies with history, offline replies from the browser's model, the engine switch, stop, fallback, no model and download passed.");
} finally { await browser.close(); }
