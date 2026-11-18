// Run against a seeded demo. Hold a fragment while the reader picks another channel.
import assert from "node:assert/strict";
import { chromium } from "../bench/env.mjs";

const browser = await chromium.launch({ channel: "chrome" });
try {
  const page = await browser.newPage();
  await page.goto(new URL("/slack", process.argv[2]).href);
  await page.waitForFunction(() => window.Stimulus?.controllers.some(c => c.identifier === "conversation"));
  const result = await page.evaluate(async () => {
    const controller = window.Stimulus.controllers.find(c => c.identifier === "conversation");
    const [first, last] = document.querySelectorAll(".sidebar li:not(.active) a[href]");
    const originalFetch = window.fetch;
    let release;
    const gate = new Promise(resolve => { release = resolve; });
    window.fetch = async (input, ...args) => {
      const url = new URL(input, location.href);
      const response = await originalFetch(input, ...args);
      if (url.pathname === first.pathname && url.searchParams.get("fragment") === "pane") await gate;
      return response;
    };
    const switchChannel = controller.switchChannel;
    const requests = [];
    controller.switchChannel = function (...args) {
      const request = switchChannel.apply(this, args);
      requests.push(request);
      return request;
    };
    try {
      first.click();
      last.click();
      if (requests.length !== 2) throw new Error("Both sidebar clicks must enter the navigation handler");
      await requests[1];
      release();
      await requests[0];
      return {
        expected: last.pathname,
        path: location.pathname,
        active: document.querySelector(".sidebar li.active a").pathname,
        expectedTitle: last.querySelector(".name").textContent,
        paneTitle: document.querySelector(".conversation h2").textContent.trim(),
      };
    } finally {
      release();
      window.fetch = originalFetch;
      controller.switchChannel = switchChannel;
    }
  });
  assert.equal(result.path, result.expected);
  assert.equal(result.active, result.expected);
  assert.equal(result.paneTitle.replace(/^#\s*/, ""), result.expectedTitle);
  console.log("Latest channel selection owns the URL, sidebar and conversation.");
} finally {
  await browser.close();
}
