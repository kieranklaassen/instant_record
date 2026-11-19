// Run with the compiled demo pointed at a seeded, local Rails sync server.
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { chromium } from "../bench/env.mjs";

const origin = process.argv[2];
const browser = await chromium.launch({ channel: "chrome" });
try {
  const maya = await browser.newPage();
  const theo = await browser.newPage();
  const subject = "Delivery " + randomUUID();
  const reply = "Received " + randomUUID();
  const open = async (page, query = "") => {
    await page.goto(new URL("/email" + query, origin).href);
    await page.getByRole("heading", { name: "Shared inbox" }).waitFor();
  };
  await open(maya);
  await open(theo, "?member=theo&inbox=support");
  await maya.getByRole("heading", { name: "Support inbox" }).waitFor();
  assert.equal(await theo.locator(".mail-folders a").count(), 1);
  await maya.getByLabel("Offline", { exact: true }).check();
  await maya.getByRole("link", { name: "Compose" }).click();
  await maya.getByLabel("To", { exact: true }).fill("dispatch@example.test");
  await maya.getByLabel("Subject", { exact: true }).fill(subject);
  await maya.getByLabel("Message", { exact: true }).fill("Please confirm receipt.");
  await maya.getByRole("button", { name: "Send message" }).click();
  await maya.getByRole("heading", { name: subject }).waitFor();
  await maya.getByLabel("Reply", { exact: true }).fill(reply);
  await maya.getByRole("button", { name: "Send reply" }).click();
  await maya.getByText(reply, { exact: true }).waitFor();
  await maya.reload();
  await maya.getByText(reply, { exact: true }).waitFor();
  assert.equal(await theo.getByRole("link", { name: new RegExp(subject) }).count(), 0);
  await maya.getByRole("link", { name: "Billing", exact: true }).click();
  await maya.getByRole("heading", { name: "Billing inbox" }).waitFor();
  assert.equal(await maya.getByText(subject, { exact: true }).count(), 0);
  await maya.getByLabel("Offline", { exact: true }).uncheck();
  await maya.getByRole("link", { name: "Support", exact: true }).click();
  const received = theo.getByRole("link", { name: new RegExp(subject) });
  await received.click();
  await theo.getByText(reply, { exact: true }).waitFor();
  await theo.getByRole("heading", { name: "Reply to dispatch@example.test" }).waitFor();
  assert.equal(await theo.getByText(reply, { exact: true }).count(), 1);
  await theo.getByRole("button", { name: "Archive conversation" }).click();
  await received.waitFor({ state: "detached" });
  await maya.getByRole("link", { name: new RegExp(subject) }).waitFor({ state: "detached" });
  await maya.getByRole("link", { name: "Jo", exact: true }).click();
  await maya.getByRole("heading", { name: "Billing inbox" }).waitFor();
  assert.equal(await maya.locator(".mail-folders a").count(), 1);
  console.log("Scoped compose, offline reply, reload, inbox switch, teammate delivery, and archive passed.");

  // Two windows opened from /email share a browser profile and default to Maya.
  const profile = await browser.newContext();
  const sender = await profile.newPage();
  const mirror = await profile.newPage();
  await open(sender);
  await open(mirror);
  await open(theo, "?member=theo&inbox=support");
  const onlineSubject = "Online " + randomUUID();
  const response = "Confirmed " + randomUUID();
  const thread = page => page.getByRole("link", { name: new RegExp(onlineSubject) });
  await sender.getByRole("link", { name: "Compose" }).click();
  await sender.getByLabel("To", { exact: true }).fill("support@example.test");
  await sender.getByLabel("Subject", { exact: true }).fill(onlineSubject);
  await sender.getByLabel("Message", { exact: true }).fill("Testing two open Support windows.");
  await sender.getByRole("button", { name: "Send message" }).click();
  await thread(mirror).waitFor();
  // This teammate uses a separate profile and can only receive through Rails.
  await thread(theo).click();
  await theo.getByRole("heading", { name: onlineSubject }).waitFor();
  await theo.getByLabel("Reply", { exact: true }).fill(response);
  await theo.getByRole("button", { name: "Send reply" }).click();
  await theo.getByText(response, { exact: true }).waitFor();
  await sender.getByText(response, { exact: true }).waitFor();
  await theo.getByRole("button", { name: "Archive conversation" }).click();
  await thread(mirror).waitFor({ state: "detached" });
  await thread(sender).waitFor({ state: "detached" });
  await mirror.getByRole("link", { name: "Compose" }).click();
  await mirror.getByLabel("Subject", { exact: true }).fill("Unfinished draft");
  const before = await theo.locator(".mail-row").evaluateAll(rows => rows.map(row => row.href));
  await sender.getByRole("button", { name: "Generate incoming email" }).click();
  await sender.getByRole("status").filter({ hasText: "Email received" }).waitFor();
  await theo.waitForFunction(previous => Array.from(document.querySelectorAll(".mail-row")).some(row => !previous.includes(row.href)), before);
  const incoming = await theo.locator(".mail-row").evaluateAll((rows, previous) => rows.find(row => !previous.includes(row.href)).getAttribute("href"), before);
  await theo.locator(`.mail-row[href="${incoming}"]`).click();
  const id = new URL(incoming, origin).searchParams.get("thread");
  await mirror.locator(`.mail-row[href$="thread=${id}"]`).waitFor();
  assert.equal(await mirror.getByLabel("Subject", { exact: true }).inputValue(), "Unfinished draft");
  await theo.getByRole("button", { name: "Archive conversation" }).click();
  console.log("Generated incoming email reached an independent teammate and preserved an open draft.");
  console.log("Online send reached both a same-profile window and an independent teammate without reload.");
} finally {
  await browser.close();
}
