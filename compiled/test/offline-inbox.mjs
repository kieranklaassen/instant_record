// The Inbox's three offline pieces, in the compiled runtime: the shell snapshot, the
// background fill of history, and search that widens from the sync server.
//
//   cd demo && bin/rails runner script/seed_offline_inbox.rb     (the sync server's database)
//   node compiled/test/offline-inbox.mjs <origin of the compiled site>
//
// Written where no compiled build could run. Where a check fails, find out first whether the
// page or this script is wrong.
import assert from "node:assert/strict";
import { chromium } from "../bench/env.mjs";

const origin = process.argv[2];
const TOTAL = 600;
const browser = await chromium.launch({ channel: "chrome" });
const said = [];
const say = line => { said.push(line); console.log(line); };

const subjects = page => page.locator(".mail-row strong").allTextContents();
const fill = page => page.evaluate(() => window.__spinel.history);
const filled = page => page.waitForFunction(() => window.__spinel.history?.done === true, null, { timeout: 120000 });
// Every request the worker makes to the sync server for this inbox, by its last path segment.
const watch = context => {
  const seen = [];
  context.on("request", request => {
    const url = new URL(request.url());
    if (url.pathname.includes("/instant_record/") || url.pathname.startsWith("/email/shell")) {
      seen.push(url.pathname.split("/").pop() + url.search);
    }
  });
  return seen;
};
// What a reader could have seen of a load: each state the page was painted in, as
// { list, rows }. A load is one paint when there is one state and it has rows.
const frames = () => {
  window.__frames = [];
  const tick = () => {
    const body = document.body;
    if (body && body.childElementCount && getComputedStyle(body).visibility !== "hidden") {
      const state = { list: !!document.querySelector(".mail-list"), rows: document.querySelectorAll(".mail-row").length > 0 };
      const last = window.__frames.at(-1);
      if (!last || last.list !== state.list || last.rows !== state.rows) window.__frames.push(state);
    }
    requestAnimationFrame(tick);
  };
  tick();
};
const onePaint = async (page, load) => {
  await page.waitForTimeout(300);
  assert.deepEqual(await page.evaluate(() => window.__frames), [{ list: true, rows: true }], load + " is painted once, with its mail");
};
const open = async (context, query = "") => {
  const page = await context.newPage();
  await page.addInitScript(frames);
  page.on("pageerror", error => { throw error; });
  await page.goto(new URL("/email?member=maya&inbox=support" + query, origin).href);
  await page.getByRole("heading", { name: "Support inbox" }).waitFor();
  await page.locator(".mail-row").first().waitFor();
  return page;
};

try {
  // 1. A first load from the shell shows what a first load from the bootstrap shows.
  const plain = await browser.newContext();
  const plainRequests = watch(plain);
  const bootstrapped = await open(plain);
  const expected = (await subjects(bootstrapped)).slice(0, 8);
  await onePaint(bootstrapped, "a first load");
  assert.ok(plainRequests.some(path => path.startsWith("bootstrap")), "a plain first load bootstraps");
  assert.ok(!plainRequests.some(path => path.startsWith("shell")), "the shell is off unless asked for");

  const shelled = await browser.newContext();
  const shellRequests = watch(shelled);
  const fromShell = await open(shelled, "&shell=1");
  assert.ok(shellRequests.some(path => path.startsWith("shell?")), "the worker asked for the shell");
  assert.ok(shellRequests.some(path => path.startsWith("file?")), "and fetched it");
  assert.ok(!shellRequests.some(path => path.startsWith("bootstrap")), "a shell load does not bootstrap");
  assert.deepEqual((await subjects(fromShell)).slice(0, 8), expected, "the shell's first screen is the bootstrap's, in the same order");
  assert.ok(shellRequests.some(path => path.startsWith("events?after=")), "the feed is asked from the shell's cursor");
  await onePaint(fromShell, "a first load from the shell");
  say("1. A shell load shows the same first screen as a bootstrap and tails the feed, and each is painted once.");

  // 2. Mail that arrives after the shell reaches a shell-loaded page, above the shell's rows.
  await fromShell.getByRole("button", { name: "Generate incoming email" }).click();
  await fromShell.waitForFunction(first => document.querySelector(".mail-row strong")?.textContent !== first, expected[0]);
  assert.deepEqual((await subjects(fromShell)).slice(1, 4), expected.slice(0, 3), "new mail sorts above the shell's rows");
  say("2. New mail lands above the shell's rows: its timestamps sort with the runtime's own.");

  // 3. The fill brings the whole inbox down, and the count stops being a floor.
  assert.match(await fromShell.locator(".mail-unread-count").textContent(), /\+ unread|unread/);
  await filled(fromShell);
  assert.ok((await fill(fromShell)).rows >= TOTAL, "the fill brought every conversation in");
  await fromShell.waitForFunction(() => !document.querySelector(".mail-unread-count")?.textContent.includes("+"));
  say("3. The fill reached the beginning: " + JSON.stringify(await fill(fromShell)));

  // 4. Offline, the whole inbox scrolls and the server is asked for nothing.
  await fromShell.getByLabel("Offline", { exact: true }).check();
  shellRequests.length = 0;
  for (let pass = 0; pass < 40; pass++) {
    await fromShell.locator(".mail-list").hover();
    await fromShell.mouse.wheel(0, 20000);
    await fromShell.waitForTimeout(250);
    if ((await subjects(fromShell)).includes("A zebra at the door")) break;
  }
  assert.ok((await subjects(fromShell)).includes("A zebra at the door"), "the oldest conversation is reachable offline");
  assert.equal(await fromShell.getByText("Older mail is unavailable").count(), 0);
  say("4. Offline, the list scrolls to the oldest conversation.");

  // 5. Offline, search answers from the local database.
  await fromShell.getByLabel("Search mail").fill("zebra");
  await fromShell.waitForFunction(() => document.querySelectorAll(".mail-row").length === 1);
  assert.deepEqual(await subjects(fromShell), ["A zebra at the door"]);
  assert.deepEqual(shellRequests.filter(path => path.startsWith("records")), [], "nothing was asked of the server");
  await fromShell.getByLabel("Search mail").fill("");
  say("5. Offline, search finds the oldest conversation locally.");

  // 6. A reload carries on from the saved state: nothing is fetched again.
  await fromShell.getByLabel("Offline", { exact: true }).uncheck();
  shellRequests.length = 0;
  await fromShell.reload();
  await fromShell.locator(".mail-row").first().waitFor();
  await onePaint(fromShell, "a reload");
  await filled(fromShell);
  // The address names the open conversation, and the worker asks for that one by id the
  // first time it boots at it (records?thread=). That is a lookup, not a page of history.
  assert.deepEqual(shellRequests.filter(path => /^(records\?type=|bootstrap|shell|file)/.test(path)), [], "a reload fetches no history");
  say("6. A reload is whole at once, in one paint, with no history request.");

  // 7. Before the fill has run, a search widens from the server. The fill is held back here.
  const partial = await browser.newContext();
  await partial.route(/\/instant_record\/records\?.*type=/, route => route.abort());
  const partialRequests = watch(partial);
  const narrow = await open(partial);
  assert.ok(!(await subjects(narrow)).includes("A zebra at the door"));
  assert.match(await narrow.locator(".mail-unread-count").textContent(), /\+ unread/, "a partial inbox counts as a floor");
  await narrow.keyboard.press("/");
  await narrow.keyboard.type("zebra");
  await narrow.locator(".mail-row strong", { hasText: "A zebra at the door" }).waitFor({ timeout: 15000 });
  assert.ok(partialRequests.some(path => path.startsWith("records?") && path.includes("search=zebra")), "the server was asked for the search");
  assert.match(narrow.url(), /[?&]q=zebra/);

  // The match is a row of the local database now: offline, the same search still finds it.
  await narrow.getByLabel("Search mail").fill("");
  await narrow.getByLabel("Offline", { exact: true }).check();
  await narrow.getByLabel("Search mail").fill("zebra");
  await narrow.locator(".mail-row strong", { hasText: "A zebra at the door" }).waitFor({ timeout: 15000 });
  // And a search the device cannot answer whole says so.
  await narrow.getByLabel("Search mail").fill("request 3");
  await narrow.getByText("Older mail needs a connection").waitFor({ timeout: 15000 });
  say("7. A search past the local window widens from the server, keeps what it found, and says when it cannot ask.");

  console.log("\nAll " + said.length + " checks passed.");
} finally {
  await browser.close();
}
