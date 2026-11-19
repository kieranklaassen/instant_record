// The Auth page: a session on the server, and a browser that holds only what
// that session may be sent. Run against a Rails-served or compiled demo with a
// seeded sync server (AuthNote.seed_demo). A compiled demo must share its
// origin with the sync server, or the session cookie never reaches it.
import assert from "node:assert/strict";
import { chromium } from "../bench/env.mjs";

const origin = process.argv[2];
const browser = await chromium.launch({ channel: "chrome" });
try {
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.goto(new URL("/auth", origin).href);
  const compiled = await page.evaluate(() => !!window.__spinel?.worker);
  // The page is redrawn after a change of session, sometimes by a reload:
  // look until the session line and the notes both say what is expected.
  const settle = async (sentence, expected) => {
    const deadline = Date.now() + 20000;
    let seen;
    while (Date.now() < deadline) {
      seen = await page.evaluate(() => ({
        who: document.querySelector("[data-auth-target=who]")?.textContent || "",
        titles: [...document.querySelectorAll(".auth-note h3")].map(node => node.textContent).sort(),
      })).catch(() => null);
      if (seen && seen.who.startsWith(sentence) && JSON.stringify(seen.titles) === JSON.stringify(expected)) return;
      await page.waitForTimeout(100);
    }
    assert.deepEqual(seen, { who: sentence, titles: expected });
  };
  const proof = async (button, pattern) => {
    await page.getByRole("button", { name: button }).click();
    await page.waitForFunction(text => new RegExp(text).test(document.querySelector(".auth-proof-out").textContent), pattern);
    return page.locator(".auth-proof-out").textContent();
  };
  // Everything this runtime's database holds, not only what the page chose to draw.
  const held = () => compiled
    ? page.evaluate(async () => (await (await fetch("/auth")).text()).match(/class="card auth-note/g)?.length || 0)
    : page.locator(".auth-note").count();

  // The page folds every change in: it is loaded once and never again.
  await page.evaluate(() => { window.__loadedOnce = true; });
  const loads = [];
  page.on("framenavigated", frame => { if (frame === page.mainFrame()) loads.push(frame.url()); });

  const everyone = ["Welcome"];
  const ben = ["Ben's gift list", "Team lunch is Thursday", "Welcome"];
  const ada = ["Ada's draft", "Payroll runs on the 28th", "Team lunch is Thursday", "Welcome"];

  // Signed out: one public note, and the sync server sends nothing else when asked.
  await settle("Signed out.", everyone);
  assert.ok(await page.locator("[data-auth-target=submit]").isDisabled());
  assert.match(await proof("Ask the sync server for everything", "sent this browser"), /sent this browser 1:/);
  assert.match(await proof("Write a note as someone else", "answered"), /rejected, not permitted/);
  assert.ok(!(await page.content()).includes("Payroll"));

  // Sign in as Ben: his notes arrive. Ada's and Cleo's never do.
  await page.getByRole("button", { name: /Ben/ }).click();
  await settle("Signed in as Ben.", ben);
  assert.equal(await page.locator("[data-auth-target=role]").textContent(), "member");
  assert.equal(await held(), 3);
  assert.match(await proof("Write a note as someone else", "answered"), /Ben tried.*rejected, not permitted/s);

  // Ben writes a note of his own, and it stays.
  await page.getByRole("textbox", { name: "Title" }).fill("Ben's new note");
  await page.getByRole("button", { name: "Add note" }).click();
  await settle("Signed in as Ben.", [...ben, "Ben's new note"].sort());
  assert.equal(await page.getByRole("textbox", { name: "Title" }).inputValue(), "");

  // Ben deletes his new note, and it closes up in place.
  await page.locator(".auth-note", { hasText: "Ben's new note" }).getByRole("button", { name: "Delete" }).click();
  await settle("Signed in as Ben.", ben);

  // Ben deletes a note that is not his. On the server page there is nothing to
  // press that works; in the browser it goes, is refused, and comes back.
  await page.locator('.auth-note[data-id="auth-welcome"]').getByRole("button", { name: "Delete" }).click();
  await page.waitForTimeout(2500); // long enough for the refusal to come back and the page to be redrawn
  await settle("Signed in as Ben.", ben);

  // Switch to Ada: Ben's own notes leave this browser, the admins' note arrives.
  await page.getByRole("button", { name: /Ada/ }).click();
  await settle("Signed in as Ada.", ada);
  assert.equal(await held(), 4);
  assert.ok(!(await page.content()).includes("gift list"));

  // Sign out: everything but the public note is taken out again.
  await page.getByRole("button", { name: "Sign out" }).click();
  await settle("Signed out.", everyone);
  assert.equal(await held(), 1);
  assert.ok(!(await page.content()).includes("Payroll"));

  // A second browser never signed in, and was never sent a secret.
  const stranger = await (await browser.newContext()).newPage();
  await stranger.goto(new URL("/auth", origin).href);
  await stranger.waitForFunction(() => document.querySelector("[data-auth-target=who]")?.textContent.startsWith("Signed out."));
  assert.deepEqual(await stranger.locator(".auth-note h3").allTextContents(), everyone);

  assert.deepEqual(loads, [], "the page was loaded again");
  assert.equal(await page.evaluate(() => window.__loadedOnce), true);
  assert.deepEqual(errors, []);
  console.log(`auth: passed (${compiled ? "compiled" : "Rails-served"})`);
} finally {
  await browser.close();
}
