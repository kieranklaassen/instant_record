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
  await maya.getByRole("link", { name: /Can we invite/ }).waitFor();
  assert.equal(await theo.locator(".mail-folders a").count(), 1);
  await maya.getByLabel("Offline", { exact: true }).check();
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
  await maya.getByRole("link", { name: /October invoice/ }).waitFor();
  await maya.getByRole("link", { name: "Support", exact: true }).click();
  const received = theo.getByRole("link", { name: new RegExp(subject) });
  await received.click();
  await theo.getByText(reply, { exact: true }).waitFor();
  await theo.getByRole("heading", { name: "Reply to dispatch@example.test" }).waitFor();
  assert.equal(await theo.getByText(reply, { exact: true }).count(), 1);
  await theo.getByRole("button", { name: "Archive conversation" }).click();
  await theo.getByRole("heading", { name: "New conversation" }).waitFor();
  await maya.getByRole("link", { name: new RegExp(subject) }).waitFor({ state: "detached" });
  await maya.getByRole("link", { name: "Jo", exact: true }).click();
  await maya.getByRole("link", { name: /October invoice/ }).waitFor();
  assert.equal(await maya.locator(".mail-folders a").count(), 1);
  console.log("Scoped compose, offline reply, reload, inbox switch, teammate delivery, and archive passed.");
} finally {
  await browser.close();
}
