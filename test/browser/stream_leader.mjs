// Real-browser verification of leader-elected, visibility-aware SSE streaming:
// exercises Chromium's real navigator.locks, BroadcastChannel, dedicated Workers,
// IndexedDB, visibilitychange, and chunked text/event-stream fetch.
//
//   node test/browser/stream_leader.mjs
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createServer } from "node:http";
import { existsSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "../..");
const streamLeaderSrc = readFileSync(join(repoRoot, "compiled/web/src/stream-leader.js"), "utf8");

async function loadChromium() {
  const candidates = [];
  if (process.env.PLAYWRIGHT_NODE_MODULES) candidates.push(process.env.PLAYWRIGHT_NODE_MODULES);

  // Also check toolchain.env in this worktree or the shared main checkout.
  const toolchainFiles = [join(repoRoot, "compiled/toolchain.env")];
  try {
    const commonGit = execFileSync("git", ["rev-parse", "--git-common-dir"], { cwd: repoRoot, encoding: "utf8" }).trim();
    toolchainFiles.push(join(dirname(commonGit), "compiled/toolchain.env"));
  } catch { /* ignore */ }

  for (const file of toolchainFiles) {
    if (!existsSync(file)) continue;
    const vars = {};
    for (const line of readFileSync(file, "utf8").split("\n")) {
      if (!line || line.startsWith("#") || !line.includes("=")) continue;
      const at = line.indexOf("=");
      let val = line.slice(at + 1);
      for (const [k, v] of Object.entries(vars)) val = val.replaceAll("$" + k, v);
      vars[line.slice(0, at)] = val;
    }
    if (vars.PLAYWRIGHT_NODE_MODULES) candidates.push(vars.PLAYWRIGHT_NODE_MODULES);
  }

  for (const dir of candidates) {
    try {
      const req = createRequire(dir + "/");
      return req("playwright-core").chromium;
    } catch { /* try next */ }
  }

  for (const pkg of ["playwright-core", "playwright"]) {
    try {
      const req = createRequire(import.meta.url);
      return req(pkg).chromium;
    } catch { /* try next */ }
  }

  throw new Error("Playwright not found. Set PLAYWRIGHT_NODE_MODULES or install playwright-core.");
}

const workerCode = `
import { createStreamLeader } from "/stream-leader.js";

const dbReady = new Promise((resolve, reject) => {
  const req = indexedDB.open("stream-leader-browser-test", 1);
  req.onupgradeneeded = () => req.result.createObjectStore("kv");
  req.onsuccess = () => resolve(req.result);
  req.onerror = () => reject(req.error);
});

async function idbGet(key) {
  const db = await dbReady;
  return new Promise((resolve, reject) => {
    const tx = db.transaction("kv", "readonly");
    const req = tx.objectStore("kv").get(key);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function idbPut(entries) {
  const db = await dbReady;
  return new Promise((resolve, reject) => {
    const tx = db.transaction("kv", "readwrite");
    const store = tx.objectStore("kv");
    for (const [k, v] of entries) store.put(v, k);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

const changes = new BroadcastChannel("stream-leader-test-changes");
const reports = [];
let streamOpen = false;
let leader = null;

changes.onmessage = event => {
  self.postMessage({ type: "records_changed", changes: event.data?.changes || null });
};

function parseEvents(framesText) {
  const parsed = [];
  for (const block of framesText.split("\\n\\n")) {
    if (!block.trim()) continue;
    const idMatch = /^id: (.+)$/m.exec(block);
    const dataMatch = /^data: (.+)$/m.exec(block);
    if (!dataMatch) continue;
    const payload = JSON.parse(dataMatch[1]);
    if (idMatch) payload.cursor = Number(idMatch[1]);
    parsed.push(payload);
  }
  return parsed;
}

self.onmessage = async event => {
  const { type, visible, offline, scope, hiddenGraceMs } = event.data;
  if (type === "boot") {
    leader = createStreamLeader({
      endpoint: "/instant_record",
      syncScope: scope || "test-scope",
      initialVisible: visible !== false,
      hiddenGraceMs: hiddenGraceMs ?? 150,
      getStreamParams: async () => {
        const cursor = (await idbGet("cursor")) ?? 0;
        return { ready: true, cursor, identity: "user-1" };
      },
      applyFrames: async framesText => {
        const events = parseEvents(framesText);
        let cursor = (await idbGet("cursor")) ?? 0;
        const appliedChanges = [];
        for (const ev of events) {
          if (ev.cursor > cursor) cursor = ev.cursor;
          appliedChanges.push({ type: ev.type, id: ev.id });
        }
        await idbPut([["cursor", cursor]]);
        changes.postMessage({ revision: cursor, changes: appliedChanges });
        self.postMessage({ type: "records_changed", changes: appliedChanges });
        return { applied: events.length, cursor, reset: false };
      },
      onReport: entry => {
        reports.push(entry);
        self.postMessage({ type: "report", entry });
      },
      onStreamStateChange: open => {
        streamOpen = open;
        self.postMessage({ type: "stream_state", streamOpen: open });
      },
    });
    leader.start();
    self.postMessage({ type: "booted", tabId: leader.tabId });
    return;
  }
  if (type === "visibility") leader?.setVisible(visible);
  else if (type === "pagehide") leader?.stop();
  else if (type === "offline") leader?.setOfflineSimulated(offline);
  else if (type === "reconnect") leader?.reconnect();
  else if (type === "status") {
    self.postMessage({
      type: "status",
      isLeader: leader?.isLeader() ?? false,
      streamOpen,
      reports,
      cursor: (await idbGet("cursor")) ?? 0,
    });
  }
};
`;

const htmlPage = `<!doctype html>
<html>
<head><meta charset="utf-8"><title>StreamLeader Test</title></head>
<body>
<script type="module">
  let simulatedHidden = false;
  Object.defineProperty(document, "visibilityState", {
    configurable: true,
    get: () => (simulatedHidden ? "hidden" : "visible"),
  });

  const worker = new Worker("/worker.js", { type: "module" });
  const received = [];
  const reports = [];
  const streamStates = [];
  let bootedResolve;
  const booted = new Promise(resolve => { bootedResolve = resolve; });

  let statusResolve = null;
  worker.onmessage = event => {
    const msg = event.data;
    if (msg.type === "booted") bootedResolve(msg.tabId);
    else if (msg.type === "records_changed") received.push(...(msg.changes || []));
    else if (msg.type === "report") reports.push(msg.entry);
    else if (msg.type === "stream_state") streamStates.push(msg.streamOpen);
    else if (msg.type === "status" && statusResolve) {
      const r = statusResolve;
      statusResolve = null;
      r(msg);
    }
  };

  const reportVisibility = () => worker.postMessage({ type: "visibility", visible: document.visibilityState !== "hidden" });
  document.addEventListener("visibilitychange", reportVisibility);
  window.addEventListener("pagehide", () => worker.postMessage({ type: "pagehide" }));

  const params = new URLSearchParams(location.search);
  worker.postMessage({
    type: "boot",
    scope: params.get("scope") || "user-scope",
    visible: document.visibilityState !== "hidden",
    hiddenGraceMs: Number(params.get("grace") || 150),
  });

  window.__harness = {
    booted,
    received: () => received.slice(),
    reports: () => reports.slice(),
    streamStates: () => streamStates.slice(),
    status: () => new Promise(resolve => {
      statusResolve = resolve;
      worker.postMessage({ type: "status" });
    }),
    setVisible(visible) {
      simulatedHidden = !visible;
      document.dispatchEvent(new Event("visibilitychange"));
    },
    setOffline(offline) {
      worker.postMessage({ type: "offline", offline: !!offline });
    },
    reconnect() {
      worker.postMessage({ type: "reconnect" });
    },
  };
</script>
</body>
</html>`;

// Real chunked SSE test server tracking every connection and event.
const eventLog = [];
const connections = [];
const activeStreams = new Set();

function pushServerEvent(type, id) {
  const cursor = eventLog.length + 1;
  const frame = `id: ${cursor}\nevent: change\ndata: ${JSON.stringify({ type, id, operation: "create", version: cursor })}\n\n`;
  eventLog.push({ cursor, frame });
  for (const res of activeStreams) {
    res.write(frame);
  }
  return cursor;
}

const server = createServer((req, res) => {
  const url = new URL(req.url, "http://127.0.0.1");
  if (url.pathname === "/") {
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
    return res.end(htmlPage);
  }
  if (url.pathname === "/stream-leader.js") {
    res.writeHead(200, { "Content-Type": "text/javascript; charset=utf-8", "Cache-Control": "no-store" });
    return res.end(streamLeaderSrc);
  }
  if (url.pathname === "/worker.js") {
    res.writeHead(200, { "Content-Type": "text/javascript; charset=utf-8", "Cache-Control": "no-store" });
    return res.end(workerCode);
  }
  if (url.pathname === "/instant_record/events") {
    const record = {
      url: req.url,
      after: Number(url.searchParams.get("after") || 0),
      scope: url.searchParams.get("scope"),
      window: url.searchParams.get("window"),
      active: true,
    };
    connections.push(record);
    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-store",
      "X-Accel-Buffering": "no",
    });
    res.write(": hb\n\n");
    for (const item of eventLog) {
      if (item.cursor > record.after) res.write(item.frame);
    }
    activeStreams.add(res);
    req.on("close", () => {
      record.active = false;
      activeStreams.delete(res);
    });
    return;
  }
  res.writeHead(404).end();
});

async function waitFor(predicate, label, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  throw new Error(`Timed out waiting for: ${label}`);
}

await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
const chromium = await loadChromium();
const browser = await chromium.launch({ channel: "chrome" }).catch(() => chromium.launch());
const pageErrors = [];

try {
  const context = await browser.newContext();
  const openTab = async () => {
    const page = await context.newPage();
    page.on("pageerror", error => pageErrors.push(error.message));
    await page.goto(`${origin}/?scope=browser-user&grace=150`);
    await page.evaluate(() => window.__harness.booted);
    return page;
  };

  // 1. Two tabs share a single SSE leader connection and both receive streamed updates.
  const tab1 = await openTab();
  const tab2 = await openTab();
  await waitFor(() => activeStreams.size === 1, "one active SSE stream");
  await waitFor(async () => {
    const [s1, s2] = await Promise.all([
      tab1.evaluate(() => window.__harness.status()),
      tab2.evaluate(() => window.__harness.status()),
    ]);
    return (s1.isLeader !== s2.isLeader) && s1.streamOpen && s2.streamOpen;
  }, "single leader and shared streamOpen");

  assert.equal(connections.length, 1, "only one /events connection opened across two tabs");
  assert.equal(connections[0].window, null, "streaming request must not pass window=0");
  assert.equal(connections[0].scope, "browser-user", "streaming request must carry scope");

  pushServerEvent("Issue", "evt-1");
  await waitFor(async () => {
    const [r1, r2] = await Promise.all([
      tab1.evaluate(() => window.__harness.received()),
      tab2.evaluate(() => window.__harness.received()),
    ]);
    return r1.some(c => c.id === "evt-1") && r2.some(c => c.id === "evt-1");
  }, "both leader and follower receive evt-1");
  console.log("✓ two tabs share one SSE stream and fan out updates via BroadcastChannel");

  // 2. Visibility pause only when ALL tabs are hidden, and immediate resume on reveal.
  const [s1Before] = await Promise.all([tab1.evaluate(() => window.__harness.status())]);
  const leaderTab = s1Before.isLeader ? tab1 : tab2;
  const followerTab = s1Before.isLeader ? tab2 : tab1;

  await leaderTab.evaluate(() => window.__harness.setVisible(false));
  await new Promise(resolve => setTimeout(resolve, 260));
  assert.equal(activeStreams.size, 1, "stream must stay open while follower tab is still visible");

  await followerTab.evaluate(() => window.__harness.setVisible(false));
  await waitFor(() => activeStreams.size === 0, "stream aborts after all tabs are hidden");
  const countPaused = connections.length;
  await new Promise(resolve => setTimeout(resolve, 260));
  assert.equal(connections.length, countPaused, "no reconnects while all tabs remain hidden");

  pushServerEvent("Issue", "evt-2");
  await followerTab.evaluate(() => window.__harness.setVisible(true));
  await waitFor(() => activeStreams.size === 1, "stream resumes immediately when follower becomes visible");
  await waitFor(async () => {
    const r = await followerTab.evaluate(() => window.__harness.received());
    return r.some(c => c.id === "evt-2");
  }, "queued evt-2 delivered on visibility resume");
  console.log("✓ visibility pauses when all tabs hide and resumes immediately on reveal");

  // 3. Closing the leader tab fails over automatically to the waiting follower at the persisted cursor.
  const connectionsBeforeClose = connections.length;
  await leaderTab.close();
  await waitFor(async () => {
    const st = await followerTab.evaluate(() => window.__harness.status());
    return st.isLeader && activeStreams.size === 1 && connections.length === connectionsBeforeClose + 1;
  }, "follower assumes leadership after leader tab closes");
  assert.equal(connections.at(-1).after, 2, "promoted leader resumes from persisted cursor 2");

  pushServerEvent("Issue", "evt-3");
  await waitFor(async () => {
    const r = await followerTab.evaluate(() => window.__harness.received());
    return r.some(c => c.id === "evt-3");
  }, "promoted leader receives evt-3");
  console.log("✓ leader tab close triggers seamless failover from persisted cursor");

  // 4. Simulated offline yields leadership to an online peer tab in the same scope.
  const tab3 = await openTab();
  await followerTab.evaluate(() => window.__harness.setOffline(true));
  await waitFor(async () => {
    const [oldLeader, newLeader] = await Promise.all([
      followerTab.evaluate(() => window.__harness.status()),
      tab3.evaluate(() => window.__harness.status()),
    ]);
    return !oldLeader.isLeader && newLeader.isLeader && activeStreams.size === 1;
  }, "tab3 takes over leadership when leader enters simulated offline");

  const offlineReports = await followerTab.evaluate(() => window.__harness.reports().filter(r => r.status === "offline"));
  assert.equal(offlineReports.length, 1, "offline tab records one offline stream report");

  pushServerEvent("Issue", "evt-4");
  await waitFor(async () => {
    const r = await tab3.evaluate(() => window.__harness.received());
    return r.some(c => c.id === "evt-4");
  }, "new online leader receives evt-4");
  console.log("✓ simulated offline releases lock so online peer takes over");

  assert.deepEqual(pageErrors, [], "zero page errors across all tabs");
  await context.close();
} finally {
  for (const res of activeStreams) res.end();
  await browser.close();
  server.close();
}
