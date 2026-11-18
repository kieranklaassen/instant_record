// Timings for the compiled app in headless Chrome. Every number is a median over repeated samples.
//   Boot times are taken on the page's own clock: the first frame in which the row is laid out.
//   cold_boot_ms  brand-new profile -> /slack -> first conversation row. Includes the download, the wasm
//                 compile, the gem's bootstrap from Rails, and any reload the page does on the way.
//   warm_boot_ms  assets cached, local database saved, nothing running -> /slack -> first conversation row.
//   switch_ms     click another channel -> its conversation is in the DOM.
//   write_ms      submit a new Todo -> its row is in the DOM (local write + render; no network on the path).
import { chromium, median } from "./env.mjs";

const CONTEXTS = Number(process.env.BENCH_CONTEXTS || 5);
const WARM_PER_CONTEXT = 3;
const SWITCHES_PER_CONTEXT = 6;
const WRITES_PER_CONTEXT = 3; // the first write in a page is slower than the rest; three keeps the median off that edge

// Runs `act` in the page and resolves with the ms until `done()` is true.
const timed = (page, act, done, arg) => page.evaluate(({ act, done, arg }) => new Promise((resolve, reject) => {
  const isDone = new Function("arg", "return (" + done + ")(arg)");
  const start = performance.now();
  const observer = new MutationObserver(() => { if (isDone(arg)) { observer.disconnect(); resolve(performance.now() - start); } });
  observer.observe(document, { childList: true, subtree: true, characterData: true, attributes: true });
  setTimeout(() => reject(new Error("timed out waiting for the page to change")), 10000);
  new Function("arg", "return (" + act + ")(arg)")(arg);
}), { act: act.toString(), done: done.toString(), arg });

// Runs in every document before its own scripts. Records, on the page's own clock, the first
// animation frame in which the awaited element is laid out. Timing from inside the page matters:
// the app replaces the shell document when it boots, and a driver-side wait notices that
// replacement about 80 ms late, which would be charged to the app.
const probe = () => {
  const targets = { conversation: "ol.messages li", todo: "form.todo-form input[type=text]" };
  window.__boot = {};
  const tick = () => {
    for (const [name, selector] of Object.entries(targets)) {
      if (window.__boot[name] !== undefined) continue;
      const element = document.querySelector(selector);
      if (!element) continue;
      const box = element.getBoundingClientRect();
      if (box.width > 0 && box.height > 0) window.__boot[name] = performance.now();
    }
    if (Object.keys(window.__boot).length === 0 && performance.now() < 60000) requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
};

// Milliseconds from asking the browser to navigate until the awaited element is laid out,
// across any reload on the way: the final document's own start time plus its in-page stamp.
const loadUntil = async (page, url, target) => {
  const started = Date.now();
  await page.goto(url);
  await page.waitForFunction((name) => window.__boot && window.__boot[name] !== undefined, target, { timeout: 60000 });
  const { origin, at } = await page.evaluate((name) => ({ origin: performance.timeOrigin, at: window.__boot[name] }), target);
  return origin - started + at;
};
const stimulus = (page, identifier) => page.waitForFunction(
  (name) => !!window.Stimulus && window.Stimulus.controllers.some((c) => c.identifier === name), identifier, { timeout: 20000 });

export async function measure(base) {
  const browser = await chromium.launch({ channel: "chrome", headless: true });
  const samples = {
    cold: [], warm: [], todoWarm: [],
    switch: [], slackSend: [], threadOpen: [], threadReply: [],
    write: [], toggle: [], del: [],
    compile: [], firstRequest: [],
  };
  let traffic = null;
  try {
    for (let run = 0; run < CONTEXTS; run++) {
      await fetch(base + "/__test/traffic?reset=1");
      const context = await browser.newContext({ viewport: { width: 1400, height: 900 } });
      await context.addInitScript(probe);

      const first = await context.newPage();
      samples.cold.push(await loadUntil(first, base + "/slack", "conversation"));
      if (run === 0) traffic = await (await fetch(base + "/__test/traffic")).json();
      await first.waitForTimeout(2000); // let the first sync finish any refresh before timing clicks
      await stimulus(first, "conversation");

      const channels = ["random", "design", "general"];
      for (let i = 0; i < SWITCHES_PER_CONTEXT; i++) {
        const name = channels[i % channels.length];
        samples.switch.push(await timed(first,
          (target) => [...document.querySelectorAll(".sidebar a")].find((a) => a.querySelector(".name")?.textContent.trim() === target).click(),
          // Turbo shows a cached preview of a channel it has seen; only the fresh render counts.
          (target) => !document.documentElement.hasAttribute("data-turbo-preview") && document.querySelector(".conversation-header h2")?.textContent.includes(target) && document.querySelectorAll("ol.messages li").length > 0,
          name));
        await first.waitForTimeout(150);
      }

      // Slack interactions: send message, open thread, send thread reply.
      const msgBody = `bench-msg-${run}-${Date.now().toString(36)}`;
      await first.fill(".composer input[type=text]", msgBody);
      samples.slackSend.push(await timed(first,
        () => document.querySelector(".composer").requestSubmit(),
        (text) => [...document.querySelectorAll("ol.messages li p.body")].some((el) => el.textContent.trim() === text),
        msgBody));
      await first.waitForTimeout(150);

      samples.threadOpen.push(await timed(first,
        (text) => {
          const row = [...document.querySelectorAll("ol.messages li")].find((li) => li.querySelector("p.body")?.textContent.trim() === text);
          row.querySelector("a.thread-link").click();
        },
        (text) => !document.documentElement.hasAttribute("data-turbo-preview") &&
          document.querySelector(".thread-parent p.body")?.textContent.trim() === text &&
          !!document.querySelector(".thread-composer input[type=text]"),
        msgBody));
      await first.waitForTimeout(150);

      const replyBody = `bench-reply-${run}-${Date.now().toString(36)}`;
      await first.fill(".thread-composer input[type=text]", replyBody);
      samples.threadReply.push(await timed(first,
        () => document.querySelector(".thread-composer").requestSubmit(),
        (text) => [...document.querySelectorAll("ol.thread-replies li p.body")].some((el) => el.textContent.trim() === text),
        replyBody));
      await first.waitForTimeout(200);

      await first.goto(base + "/todo");
      await first.waitForSelector("form.todo-form input[type=text]", { timeout: 20000 });
      await stimulus(first, "issues");
      const createdTitles = [];
      for (let i = 0; i < WRITES_PER_CONTEXT; i++) {
        const title = `bench ${run}-${i}-${Date.now().toString(36)}`;
        createdTitles.push(title);
        await first.fill("form.todo-form input[type=text]", title);
        samples.write.push(await timed(first,
          () => document.querySelector("form.todo-form").requestSubmit(),
          (text) => [...document.querySelectorAll("ul.issues li label.title")].some((el) => el.textContent.trim() === text),
          title));
        await first.waitForTimeout(200);
      }
      // Todo click interactions: toggle checkbox and delete row.
      for (const title of createdTitles) {
        samples.toggle.push(await timed(first,
          (text) => {
            const li = [...document.querySelectorAll("ul.issues li")].find((el) => el.querySelector("label.title")?.textContent.trim() === text);
            li.querySelector("input[type=checkbox]").click();
          },
          (text) => {
            const li = [...document.querySelectorAll("ul.issues li")].find((el) => el.querySelector("label.title")?.textContent.trim() === text);
            return !!li && li.classList.contains("done");
          },
          title));
        await first.waitForTimeout(200);
      }
      for (const title of createdTitles) {
        samples.del.push(await timed(first,
          (text) => {
            const li = [...document.querySelectorAll("ul.issues li")].find((el) => el.querySelector("label.title")?.textContent.trim() === text);
            li.querySelector("form.button_to button").click();
          },
          (text) => ![...document.querySelectorAll("ul.issues li label.title")].some((el) => el.textContent.trim() === text),
          title));
        await first.waitForTimeout(200);
      }
      await first.waitForTimeout(600); // let the debounced save land before closing
      await first.close();

      for (let i = 0; i < WARM_PER_CONTEXT; i++) {
        const page = await context.newPage();
        samples.warm.push(await loadUntil(page, base + "/slack", "conversation"));
        const marks = await page.evaluate(() => window.__spinel?.marks ?? {});
        if (typeof marks.compileMs === "number") samples.compile.push(marks.compileMs);
        if (typeof marks.firstRequestMs === "number") samples.firstRequest.push(marks.firstRequestMs);
        await page.close();
      }
      const todo = await context.newPage();
      samples.todoWarm.push(await loadUntil(todo, base + "/todo", "todo"));
      await context.close();
    }
  } finally {
    await browser.close();
  }

  const once = new Map();
  for (const entry of traffic ?? []) once.set(entry.path, entry);
  const files = [...once.values()];
  const wasm = files.find((entry) => entry.path.endsWith(".wasm"));
  const round = (value) => Math.round(value * 10) / 10;
  const switchMs = round(median(samples.switch));
  const slackSendMs = round(median(samples.slackSend));
  const threadOpenMs = round(median(samples.threadOpen));
  const threadReplyMs = round(median(samples.threadReply));
  const writeMs = round(median(samples.write));
  const toggleMs = round(median(samples.toggle));
  const deleteMs = round(median(samples.del));
  const interactionMs = round((switchMs + slackSendMs + threadOpenMs + threadReplyMs + writeMs + toggleMs + deleteMs) / 7);
  return {
    interaction_ms: interactionMs,
    warm_boot_ms: round(median(samples.warm)),
    cold_boot_ms: round(median(samples.cold)),
    switch_ms: switchMs,
    slack_send_ms: slackSendMs,
    thread_open_ms: threadOpenMs,
    thread_reply_ms: threadReplyMs,
    write_ms: writeMs,
    toggle_ms: toggleMs,
    delete_ms: deleteMs,
    todo_warm_boot_ms: round(median(samples.todoWarm)),
    wasm_compile_ms: samples.compile.length ? round(median(samples.compile)) : -1,
    first_request_ms: samples.firstRequest.length ? round(median(samples.firstRequest)) : -1,
    first_visit_gzip_bytes: files.reduce((sum, entry) => sum + entry.sent, 0),
    first_visit_raw_bytes: files.reduce((sum, entry) => sum + entry.raw, 0),
    wasm_gzip_bytes: wasm ? wasm.sent : -1,
    wasm_raw_bytes: wasm ? wasm.raw : -1,
    sample_counts: Object.fromEntries(Object.entries(samples).map(([name, values]) => [name, values.length])),
    samples: Object.fromEntries(Object.entries(samples).map(([name, values]) => [name, values.map((value) => Math.round(value))])),
    sample_ranges: Object.fromEntries(Object.entries(samples).filter(([, v]) => v.length).map(([name, values]) => [name, [Math.round(Math.min(...values)), Math.round(Math.max(...values))]])),
  };
}
