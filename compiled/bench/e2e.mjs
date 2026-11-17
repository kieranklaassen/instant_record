// Behavior checks: the compiled app against the real Rails sync server, in headless Chrome.
// Returns a map of check id -> true/false. A faster build that fails any of these is not a result.
import { chromium, rows, runner, sleep, until } from "./env.mjs";

export async function behaviorChecks(base) {
  const cases = {};
  const failures = [];
  const step = async (id, fn) => {
    try { await fn(); cases[id] = true; }
    catch (error) { cases[id] = false; failures.push({ check: id, problem: String(error.message).split("\n")[0].slice(0, 200) }); }
  };

  const stamp = Date.now().toString(36);
  const todo = "check todo " + stamp;
  const fromServer = "check server todo " + stamp;
  const chat = "check chat " + stamp;
  const reply = "check reply " + stamp;

  const browser = await chromium.launch({ channel: "chrome", headless: true });
  try {
    const context = await browser.newContext({ viewport: { width: 1400, height: 900 } });
    const page = await context.newPage();
    const pageErrors = [];
    page.on("pageerror", (error) => pageErrors.push(error.message));

    const texts = (selector, on = page) => on.$$eval(selector, (els) => els.map((el) => el.textContent.replace(/\s+/g, " ").trim()));
    const issueTitles = (on = page) => texts("ul.issues li label.title", on);
    const issueRow = (title) => page.locator("ul.issues li", { has: page.locator("label.title", { hasText: title }) });
    const bodies = (on = page) => texts("ol.messages li p.body", on);
    const pendingIsZero = async () => (await texts("#pending-count"))[0]?.startsWith("0 ");

    await step("todo_renders_with_stimulus", async () => {
      await page.goto(base + "/todo");
      await page.waitForSelector("form.todo-form input[type=text]", { timeout: 20000 });
      await until("stimulus", () => page.evaluate(() => !!window.Stimulus && window.Stimulus.controllers.some((c) => c.identifier === "issues")));
    });
    await step("todo_create_reaches_rails", async () => {
      await page.fill("form.todo-form input[type=text]", todo);
      await page.click("form.todo-form input[type=submit]");
      await until("local row", async () => (await issueTitles()).includes(todo));
      const row = await until("rails row", () => rows("issues", `title = '${todo}'`)[0]);
      if (row.server_version !== 1 || row.state !== "open" || !/^[0-9a-f-]{36}$/.test(row.id)) throw new Error("rails row " + JSON.stringify(row));
      await until("pending 0", pendingIsZero);
    });
    await step("todo_toggle_reaches_rails", async () => {
      await issueRow(todo).locator("input[type=checkbox]").click();
      await until("rails done", () => rows("issues", `title = '${todo}' and state = 'done' and server_version = 2`)[0]);
    });
    await step("todo_server_create_arrives", async () => {
      runner(`Issue.create!(title: "${fromServer}")`);
      await until("row", async () => (await issueTitles()).includes(fromServer));
    });
    await step("todo_server_rejection_rolls_back", async () => {
      await page.fill("form.todo-form input[type=text]", "reject me");
      await page.click("form.todo-form input[type=submit]");
      await until("rolled back", async () => !(await issueTitles()).includes("reject me") && (await pendingIsZero()), 20000);
      if (rows("issues", "title = 'reject me'").length) throw new Error("rails stored the rejected row");
    });
    await step("todo_delete_reaches_rails", async () => {
      await issueRow(fromServer).locator("form.button_to button").click();
      await until("gone", () => rows("issues", `title = '${fromServer}'`).length === 0);
    });
    await step("slack_opens_general_with_window", async () => {
      await page.goto(base + "/slack");
      await page.waitForSelector("ol.messages li", { timeout: 20000 });
      if (!page.url().endsWith("/slack/channels/channel-general")) throw new Error("url " + page.url());
      const names = await texts(".sidebar .name");
      for (const want of ["design", "general", "random", "Max Baseline"]) if (!names.includes(want)) throw new Error("sidebar " + JSON.stringify(names));
      if ((await bodies()).length < 40) throw new Error("rows " + (await bodies()).length);
      const active = await texts(".sidebar li.active .name");
      if (JSON.stringify(active) !== JSON.stringify(["general"])) throw new Error("active " + JSON.stringify(active));
    });
    await step("slack_post_and_bot_reply", async () => {
      await page.fill(".composer input[type=text]", chat);
      await page.press(".composer input[type=text]", "Enter");
      await until("local row", async () => (await bodies()).includes(chat));
      const row = await until("rails row", () => rows("messages", `body = '${chat}'`)[0]);
      if (row.channel_id !== "channel-general" || row.chat_user_id !== "you") throw new Error("rails row " + JSON.stringify(row));
      const bot = await until("rails bot reply", () => rows("messages", `channel_id = 'channel-general' and chat_user_id like 'bot-%' and parent_message_id is null and created_at > now() - interval '30 seconds'`)[0], 20000);
      await until("bot row in tab", async () => (await page.locator(`ol.messages li[data-id="${bot.id}"]`).count()) === 1);
    });
    await step("slack_thread_reply_reaches_rails", async () => {
      const parent = rows("messages", `body = '${chat}'`)[0];
      await page.goto(base + `/slack/channels/channel-general?thread=${parent.id}`);
      await page.waitForSelector(".thread-composer input[type=text]", { timeout: 20000 });
      await page.fill(".thread-composer input[type=text]", reply);
      await page.press(".thread-composer input[type=text]", "Enter");
      const row = await until("rails reply", () => rows("messages", `body = '${reply}'`)[0]);
      if (row.parent_message_id !== parent.id) throw new Error("rails row " + JSON.stringify(row));
      await until("reply in panel", async () => (await texts("ol.thread-replies li p.body")).includes(reply));
    });
    await step("reload_keeps_local_data", async () => {
      await sleep(600);
      await page.goto(base + "/todo");
      await page.waitForSelector("ul.issues li", { timeout: 20000 });
      if (!(await issueTitles()).includes(todo)) throw new Error("issue missing after reload");
    });
    await step("fresh_browser_bootstraps", async () => {
      const other = await browser.newContext();
      const tab = await other.newPage();
      await tab.goto(base + "/todo");
      await until("bootstrapped", async () => (await issueTitles(tab)).includes(todo), 20000);
      await other.close();
    });
    await step("no_page_errors", async () => {
      if (pageErrors.length) throw new Error(pageErrors[0]);
    });
  } finally {
    await browser.close();
  }
  return { cases, failures };
}
