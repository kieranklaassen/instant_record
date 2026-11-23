import assert from "node:assert/strict";
import { test } from "node:test";
import { SseFrameBuffer, createStreamLeader, eventsUrl, streamScopeKey } from "./stream-leader.js";

// Minimal in-memory Web Locks implementation mirroring navigator.locks exclusive queuing + AbortSignal.
function createFakeLocks() {
  const queues = new Map();
  const held = new Set();

  function pump(name) {
    if (held.has(name)) return;
    const queue = queues.get(name);
    if (!queue || queue.length === 0) return;
    const next = queue.shift();
    held.add(name);
    if (next.cleanup) next.cleanup();
    Promise.resolve()
      .then(() => next.callback({ name, mode: "exclusive" }))
      .then(
        val => {
          held.delete(name);
          next.resolve(val);
          pump(name);
        },
        err => {
          held.delete(name);
          next.reject(err);
          pump(name);
        },
      );
  }

  return {
    request(name, options, callback) {
      if (typeof options === "function") {
        callback = options;
        options = {};
      }
      const signal = options?.signal;
      if (signal?.aborted) {
        return Promise.reject(Object.assign(new Error("Aborted"), { name: "AbortError" }));
      }
      return new Promise((resolve, reject) => {
        const entry = { callback, resolve, reject, cleanup: null };
        if (signal) {
          const onAbort = () => {
            const queue = queues.get(name);
            if (queue) {
              const idx = queue.indexOf(entry);
              if (idx !== -1) queue.splice(idx, 1);
            }
            reject(Object.assign(new Error("Aborted"), { name: "AbortError" }));
          };
          signal.addEventListener("abort", onAbort, { once: true });
          entry.cleanup = () => signal.removeEventListener("abort", onAbort);
        }
        if (!queues.has(name)) queues.set(name, []);
        queues.get(name).push(entry);
        pump(name);
      });
    },
  };
}

// Minimal in-memory BroadcastChannel hub: delivers asynchronously to other peers on the same channel name.
function createFakeChannelHub() {
  const channels = new Map();
  return name => {
    if (!channels.has(name)) channels.set(name, new Set());
    const peers = channels.get(name);
    const ch = {
      name,
      onmessage: null,
      closed: false,
      postMessage(data) {
        if (ch.closed) return;
        const copy = structuredClone(data);
        queueMicrotask(() => {
          for (const peer of peers) {
            if (peer !== ch && !peer.closed && typeof peer.onmessage === "function") {
              peer.onmessage({ data: copy });
            }
          }
        });
      },
      close() {
        ch.closed = true;
        peers.delete(ch);
      },
    };
    peers.add(ch);
    return ch;
  };
}

// Controllable streaming fetch response helper.
function createControllableStream(signal) {
  const encoder = new TextEncoder();
  let controllerRef;
  let closed = false;
  const body = new ReadableStream({
    start(controller) {
      controllerRef = controller;
      if (signal) {
        signal.addEventListener("abort", () => {
          if (!closed) {
            closed = true;
            try { controller.error(Object.assign(new Error("Aborted"), { name: "AbortError" })); } catch {}
          }
        }, { once: true });
      }
    },
  });
  return {
    response: { status: 200, ok: true, body },
    push(text) {
      if (!closed) controllerRef.enqueue(encoder.encode(text));
    },
    close() {
      if (!closed) {
        closed = true;
        try { controllerRef.close(); } catch {}
      }
    },
    isClosed: () => closed,
  };
}

async function waitFor(predicate, timeoutMs = 1500) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 5));
  }
  throw new Error("Timed out waiting for condition");
}

test("SseFrameBuffer splits frames across arbitrary and CRLF-split chunks and ignores heartbeats", () => {
  const buf = new SseFrameBuffer();
  assert.deepEqual(buf.feed(": hb\n\n"), { framesText: "", count: 0 });

  // Split \r\n\r\n right between \r and \n across chunks
  assert.deepEqual(buf.feed('id: 1\r\nevent: change\r\ndata: {"id":"a"}\r'), { framesText: "", count: 0 });
  assert.deepEqual(buf.feed("\n\r"), { framesText: "", count: 0 });
  assert.deepEqual(buf.feed("\n: hb\r\n\r\nid: 2\ndata: {\"id\":\"b\"}\n\npartial"), {
    framesText: 'id: 1\nevent: change\ndata: {"id":"a"}\n\nid: 2\ndata: {"id":"b"}\n\n',
    count: 2,
  });

  // Reset discards half-received trailing frame so a reconnect never corrupts the next frame
  buf.reset();
  assert.deepEqual(buf.feed('id: 3\ndata: {"id":"c"}\n\n'), {
    framesText: 'id: 3\ndata: {"id":"c"}\n\n',
    count: 1,
  });
});

test("eventsUrl includes cursor, identity, and scope, and never appends window=0", () => {
  assert.equal(eventsUrl("/instant_record", { cursor: 42 }), "/instant_record/events?after=42");
  assert.equal(
    eventsUrl("/instant_record", { cursor: 7, identity: "abc 123", scope: "tok/1" }),
    "/instant_record/events?after=7&identity=abc%20123&scope=tok%2F1",
  );
  assert.doesNotMatch(eventsUrl("/instant_record", { cursor: 1 }), /window=0/);
});

test("streamScopeKey isolates distinct mailbox scopes and sync scopes", () => {
  assert.notEqual(streamScopeKey("maya/support", "s1"), streamScopeKey("theo/support", "s1"));
  assert.notEqual(streamScopeKey("", "s1"), streamScopeKey("", "s2"));
  assert.equal(streamScopeKey("", "s1"), streamScopeKey("", "s1"));
});

test("two tabs elect one leader that streams SSE without window=0 and delivers frames", async () => {
  const locks = createFakeLocks();
  const createChannel = createFakeChannelHub();
  const requests = [];
  const streams = [];
  const applied = [];
  const statesA = [];
  const statesB = [];

  const fakeFetch = async (url, init) => {
    requests.push(url);
    const stream = createControllableStream(init.signal);
    streams.push(stream);
    return stream.response;
  };

  let cursor = 10;
  const makeLeader = (tabId, states) => createStreamLeader({
    tabId,
    endpoint: "/instant_record",
    syncScope: "user-1",
    locks,
    createChannel,
    fetch: fakeFetch,
    getStreamParams: async () => ({ ready: true, cursor, identity: "id-1" }),
    applyFrames: async text => {
      applied.push({ tabId, text });
      cursor = 11;
      return { applied: 1, cursor: 11, reset: false };
    },
    onStreamStateChange: open => states.push(open),
  });

  const a = makeLeader("tab-a", statesA);
  const b = makeLeader("tab-b", statesB);
  a.start();
  b.start();

  await waitFor(() => streams.length === 1 && a.isStreamOpen() && b.isStreamOpen());
  assert.equal(a.isLeader(), true);
  assert.equal(b.isLeader(), false);
  assert.equal(requests.length, 1);
  assert.equal(requests[0], "/instant_record/events?after=10&identity=id-1&scope=user-1");

  // Heartbeat does not invoke applyFrames
  streams[0].push(": hb\n\n");
  await new Promise(r => setTimeout(r, 20));
  assert.equal(applied.length, 0);

  // Real SSE event is delivered only to the leader
  streams[0].push('id: 11\nevent: change\ndata: {"type":"Issue","id":"1"}\n\n');
  await waitFor(() => applied.length === 1);
  assert.equal(applied[0].tabId, "tab-a");
  assert.equal(requests.length, 1);

  a.stop();
  b.stop();
});

test("closing the leader promotes a waiting follower from the latest cursor", async () => {
  const locks = createFakeLocks();
  const createChannel = createFakeChannelHub();
  const requests = [];
  const streams = [];
  let sharedCursor = 5;

  const fakeFetch = async (url, init) => {
    requests.push(url);
    const stream = createControllableStream(init.signal);
    streams.push(stream);
    return stream.response;
  };

  const makeTab = tabId => createStreamLeader({
    tabId,
    endpoint: "/instant_record",
    syncScope: "user-1",
    locks,
    createChannel,
    fetch: fakeFetch,
    getStreamParams: async () => ({ ready: true, cursor: sharedCursor, identity: "" }),
    applyFrames: async () => {
      sharedCursor += 1;
      return { applied: 1, cursor: sharedCursor, reset: false };
    },
  });

  const a = makeTab("tab-a");
  const b = makeTab("tab-b");
  a.start();
  b.start();

  await waitFor(() => streams.length === 1);
  streams[0].push('id: 6\nevent: change\ndata: {"type":"Issue","id":"6"}\n\n');
  await waitFor(() => sharedCursor === 6);

  // Leader closes -> follower immediately assumes leadership at cursor 6
  a.stop();
  await waitFor(() => b.isLeader() && requests.length === 2);
  assert.equal(requests[1], "/instant_record/events?after=6&scope=user-1");

  b.stop();
});

test("visibility pauses when all tabs hide past grace period and resumes when any tab becomes visible", async () => {
  const locks = createFakeLocks();
  const createChannel = createFakeChannelHub();
  const streams = [];
  const requests = [];

  const fakeFetch = async (url, init) => {
    requests.push(url);
    const stream = createControllableStream(init.signal);
    streams.push(stream);
    return stream.response;
  };

  const makeTab = tabId => createStreamLeader({
    tabId,
    endpoint: "/instant_record",
    syncScope: "user-1",
    locks,
    createChannel,
    fetch: fakeFetch,
    hiddenGraceMs: 40,
    getStreamParams: async () => ({ ready: true, cursor: 1, identity: "" }),
    applyFrames: async () => ({ applied: 0, cursor: 1, reset: false }),
  });

  const a = makeTab("tab-a");
  const b = makeTab("tab-b");
  a.start();
  b.start();

  await waitFor(() => streams.length === 1 && a.isStreamOpen());

  // Hiding only leader while follower is still visible keeps stream open past grace period
  a.setVisible(false);
  await new Promise(r => setTimeout(r, 80));
  assert.equal(streams[0].isClosed(), false, "stream must stay open while follower is visible");

  // Hiding the follower too pauses and aborts after grace period
  b.setVisible(false);
  await waitFor(() => streams[0].isClosed() && !a.isStreamOpen());
  const countWhilePaused = requests.length;
  await new Promise(r => setTimeout(r, 80));
  assert.equal(requests.length, countWhilePaused, "no reconnects while all tabs are hidden");

  // Revealing the follower immediately wakes the leader and opens a fresh stream
  b.setVisible(true);
  await waitFor(() => requests.length === countWhilePaused + 1 && a.isStreamOpen());

  a.stop();
  b.stop();
});

test("simulated offline yields leadership to an online peer and logs one offline report", async () => {
  const locks = createFakeLocks();
  const createChannel = createFakeChannelHub();
  const streams = [];
  const reportsA = [];

  const fakeFetch = async (_url, init) => {
    const stream = createControllableStream(init.signal);
    streams.push(stream);
    return stream.response;
  };

  const makeTab = (tabId, onReport) => createStreamLeader({
    tabId,
    endpoint: "/instant_record",
    syncScope: "user-1",
    locks,
    createChannel,
    fetch: fakeFetch,
    getStreamParams: async () => ({ ready: true, cursor: 1, identity: "" }),
    applyFrames: async () => ({ applied: 0, cursor: 1, reset: false }),
    onReport,
  });

  const a = makeTab("tab-a", r => reportsA.push(r));
  const b = makeTab("tab-b", () => {});
  a.start();
  b.start();

  await waitFor(() => a.isLeader() && streams.length === 1);

  // Leader toggles simulated offline -> logs once, aborts stream, releases lock -> follower takes over
  a.setOfflineSimulated(true);
  await waitFor(() => !a.isLeader() && b.isLeader() && streams.length === 2);
  assert.equal(reportsA.filter(r => r.status === "offline").length, 1);

  // Rapid toggle on follower while queued doesn't break or duplicate leadership
  a.setOfflineSimulated(false);
  a.setOfflineSimulated(true);
  a.setOfflineSimulated(false);
  await new Promise(r => setTimeout(r, 30));
  assert.equal(b.isLeader(), true);
  assert.equal(a.isLeader(), false);

  a.stop();
  b.stop();
});

test("short-closing 200 OK endpoints wait shortStreamDelayMs instead of tight-looping, and errors back off", async () => {
  const locks = createFakeLocks();
  const createChannel = createFakeChannelHub();
  const times = [];
  let mode = "short-ok";

  const fakeFetch = async () => {
    times.push(Date.now());
    if (mode === "short-ok") {
      return { status: 200, ok: true, body: null, text: async () => "" };
    }
    return { status: 500, ok: false, body: null, text: async () => "" };
  };

  const leader = createStreamLeader({
    tabId: "solo",
    endpoint: "/email/sync/maya/support",
    mailboxScope: "maya/support",
    syncScope: "s1",
    locks,
    createChannel,
    fetch: fakeFetch,
    minStreamDurationMs: 200,
    shortStreamDelayMs: 60,
    backoffBaseMs: 50,
    backoffCapMs: 200,
    random: () => 0.5, // deterministic 1.0x jitter factor
    getStreamParams: async () => ({ ready: true, cursor: 1, identity: "" }),
    applyFrames: async () => ({ applied: 0, cursor: 1, reset: false }),
  });

  leader.start();
  await waitFor(() => times.length >= 2);
  assert.ok(times[1] - times[0] >= 45, `expected short-stream delay >= 45ms, got ${times[1] - times[0]}ms`);

  // Switch to 500 errors -> exponential backoff grows
  mode = "error";
  const errStart = times.length;
  await waitFor(() => times.length >= errStart + 3);
  const gap1 = times[errStart + 1] - times[errStart];
  const gap2 = times[errStart + 2] - times[errStart + 1];
  assert.ok(gap2 > gap1, `expected backoff to grow (${gap1}ms -> ${gap2}ms)`);

  leader.stop();
});

test("reconnect aborts open stream immediately and reset breaks stream cleanly", async () => {
  const locks = createFakeLocks();
  const createChannel = createFakeChannelHub();
  const streams = [];
  const requests = [];
  let identity = "anon";

  const fakeFetch = async (url, init) => {
    requests.push(url);
    const stream = createControllableStream(init.signal);
    streams.push(stream);
    return stream.response;
  };

  const a = createStreamLeader({
    tabId: "tab-a",
    endpoint: "/instant_record",
    syncScope: "s1",
    locks,
    createChannel,
    fetch: fakeFetch,
    getStreamParams: async () => ({ ready: true, cursor: 3, identity }),
    applyFrames: async text => ({ applied: 1, cursor: 0, reset: text.includes('"reset"') }),
  });
  const b = createStreamLeader({
    tabId: "tab-b",
    endpoint: "/instant_record",
    syncScope: "s1",
    locks,
    createChannel,
    fetch: fakeFetch,
    getStreamParams: async () => ({ ready: true, cursor: 3, identity }),
    applyFrames: async () => ({ applied: 0, cursor: 3, reset: false }),
  });

  a.start();
  b.start();
  await waitFor(() => streams.length === 1);
  assert.match(requests[0], /identity=anon/);

  // Follower signals reconnect after session change -> leader aborts and reopens with new identity
  identity = "ben";
  b.reconnect();
  await waitFor(() => streams.length === 2 && streams[0].isClosed());
  assert.match(requests[1], /identity=ben/);

  // Server sends reset frame -> leader breaks stream cleanly and reconnects
  streams[1].push('event: reset\ndata: {"operation":"reset","types":["AuthNote"]}\n\n');
  await waitFor(() => streams.length === 3 && streams[1].isClosed());

  a.stop();
  b.stop();
});

test("stale visible peer that vanished without bye is pruned so hidden leader pauses", async () => {
  const locks = createFakeLocks();
  const createChannel = createFakeChannelHub();
  const streams = [];
  let clock = 1000;

  const fakeFetch = async (_url, init) => {
    const stream = createControllableStream(init.signal);
    streams.push(stream);
    return stream.response;
  };

  const a = createStreamLeader({
    tabId: "tab-a",
    endpoint: "/instant_record",
    syncScope: "s1",
    locks,
    createChannel,
    fetch: fakeFetch,
    now: () => clock,
    hiddenGraceMs: 20,
    peerTtlMs: 100,
    peerPingWaitMs: 25,
    minStreamDurationMs: 0,
    reconnectJitterMinMs: 5,
    reconnectJitterMaxMs: 5,
    getStreamParams: async () => ({ ready: true, cursor: 1, identity: "" }),
    applyFrames: async () => ({ applied: 0, cursor: 1, reset: false }),
  });

  // Simulate a follower channel that announces itself visible and then crashes (closes without bye)
  const ghostChannel = createChannel(a.channelName);
  a.start();
  await waitFor(() => streams.length === 1);

  ghostChannel.postMessage({ type: "hello", tabId: "ghost", visible: true });
  await new Promise(r => setTimeout(r, 15));
  ghostChannel.close(); // crashed without sending bye

  // Leader hides; advance clock past peerTtlMs and close current window -> leader pings, prunes ghost, and pauses
  a.setVisible(false);
  clock += 500;
  streams[0].close();

  await waitFor(() => !a.isStreamOpen());
  await new Promise(r => setTimeout(r, 80));
  assert.equal(streams.length, 1, "crashed peer must be pruned so hidden leader does not reopen stream");

  a.stop();
});

test("browser offline pauses stream without retries and online resumes immediately", async () => {
  const locks = createFakeLocks();
  const createChannel = createFakeChannelHub();
  const streams = [];
  let isOnline = true;

  const fakeFetch = async (_url, init) => {
    const stream = createControllableStream(init.signal);
    streams.push(stream);
    return stream.response;
  };

  const a = createStreamLeader({
    tabId: "tab-a",
    endpoint: "/instant_record",
    syncScope: "s1",
    locks,
    createChannel,
    fetch: fakeFetch,
    isOnline: () => isOnline,
    getStreamParams: async () => ({ ready: true, cursor: 1, identity: "" }),
    applyFrames: async () => ({ applied: 0, cursor: 1, reset: false }),
  });

  a.start();
  await waitFor(() => streams.length === 1 && a.isStreamOpen());

  isOnline = false;
  a.setOnline(false);
  await waitFor(() => streams[0].isClosed() && !a.isStreamOpen());
  await new Promise(r => setTimeout(r, 40));
  assert.equal(streams.length, 1);

  isOnline = true;
  a.setOnline(true);
  await waitFor(() => streams.length === 2 && a.isStreamOpen());

  a.stop();
});

test("hidden follower promoted after leader disappears stays paused until a tab becomes visible", async () => {
  const locks = createFakeLocks();
  const createChannel = createFakeChannelHub();
  const streams = [];

  const fakeFetch = async (_url, init) => {
    const stream = createControllableStream(init.signal);
    streams.push(stream);
    return stream.response;
  };

  const a = createStreamLeader({
    tabId: "tab-a",
    endpoint: "/instant_record",
    syncScope: "s1",
    locks,
    createChannel,
    fetch: fakeFetch,
    initialVisible: true,
    getStreamParams: async () => ({ ready: true, cursor: 1, identity: "" }),
    applyFrames: async () => ({ applied: 0, cursor: 1, reset: false }),
  });
  const b = createStreamLeader({
    tabId: "tab-b",
    endpoint: "/instant_record",
    syncScope: "s1",
    locks,
    createChannel,
    fetch: fakeFetch,
    initialVisible: false,
    getStreamParams: async () => ({ ready: true, cursor: 1, identity: "" }),
    applyFrames: async () => ({ applied: 0, cursor: 1, reset: false }),
  });

  a.start();
  b.start();
  await waitFor(() => a.isLeader() && streams.length === 1);

  a.stop();
  await waitFor(() => b.isLeader());
  await new Promise(r => setTimeout(r, 40));
  assert.equal(streams.length, 1, "hidden promoted leader must not open a stream while no tab is visible");

  b.setVisible(true);
  await waitFor(() => streams.length === 2 && b.isStreamOpen());

  b.stop();
});

test("getSyncScope getter isolates lockName and channelName across distinct scopes", () => {
  const a = createStreamLeader({
    endpoint: "/instant_record",
    getSyncScope: () => "scope-a",
    getStreamParams: async () => ({ ready: false }),
    applyFrames: async () => ({ applied: 0, cursor: 0, reset: false }),
  });
  const b = createStreamLeader({
    endpoint: "/instant_record",
    getSyncScope: () => "scope-b",
    getStreamParams: async () => ({ ready: false }),
    applyFrames: async () => ({ applied: 0, cursor: 0, reset: false }),
  });
  assert.notEqual(a.lockName, b.lockName);
  assert.notEqual(a.channelName, b.channelName);
  assert.match(a.lockName, /scope-a$/);
  assert.match(b.lockName, /scope-b$/);
});

test("rapid simulated offline -> online toggle on leader re-acquires leadership without stranding", async () => {
  const locks = createFakeLocks();
  const createChannel = createFakeChannelHub();
  const streams = [];

  const fakeFetch = async (_url, init) => {
    const stream = createControllableStream(init.signal);
    streams.push(stream);
    return stream.response;
  };

  const a = createStreamLeader({
    tabId: "tab-a",
    endpoint: "/instant_record",
    getSyncScope: () => "s1",
    locks,
    createChannel,
    fetch: fakeFetch,
    getStreamParams: async () => ({ ready: true, cursor: 1, identity: "" }),
    applyFrames: async () => ({ applied: 0, cursor: 1, reset: false }),
  });

  a.start();
  await waitFor(() => a.isLeader() && streams.length === 1);

  // Synchronous offline -> online toggle before leadership release microtask runs
  a.setOfflineSimulated(true);
  a.setOfflineSimulated(false);
  await waitFor(() => a.isLeader() && streams.length === 2 && a.isStreamOpen());

  a.stop();
});

test("new visible tab arriving during hidden grace period wakes leader immediately", async () => {
  const locks = createFakeLocks();
  const createChannel = createFakeChannelHub();
  const streams = [];

  const fakeFetch = async (_url, init) => {
    const stream = createControllableStream(init.signal);
    streams.push(stream);
    return stream.response;
  };

  const a = createStreamLeader({
    tabId: "tab-a",
    endpoint: "/instant_record",
    getSyncScope: () => "s1",
    locks,
    createChannel,
    fetch: fakeFetch,
    hiddenGraceMs: 500,
    minStreamDurationMs: 0,
    reconnectJitterMinMs: 5,
    reconnectJitterMaxMs: 5,
    getStreamParams: async () => ({ ready: true, cursor: 1, identity: "" }),
    applyFrames: async () => ({ applied: 0, cursor: 1, reset: false }),
  });

  a.start();
  await waitFor(() => streams.length === 1 && a.isStreamOpen());

  // Leader hides and its current window closes while still inside the 500ms grace period.
  a.setVisible(false);
  streams[0].close();
  await new Promise(r => setTimeout(r, 30));

  // A new visible tab boots and sends hello (no explicit wake): leader must wake immediately.
  const b = createStreamLeader({
    tabId: "tab-b",
    endpoint: "/instant_record",
    getSyncScope: () => "s1",
    locks,
    createChannel,
    fetch: fakeFetch,
    initialVisible: true,
    getStreamParams: async () => ({ ready: true, cursor: 1, identity: "" }),
    applyFrames: async () => ({ applied: 0, cursor: 1, reset: false }),
  });
  b.start();

  await waitFor(() => streams.length === 2 && a.isStreamOpen());

  a.stop();
  b.stop();
});

test("suspend and resume support BFCache without permanently killing leadership", async () => {
  const locks = createFakeLocks();
  const createChannel = createFakeChannelHub();
  const streams = [];

  const fakeFetch = async (_url, init) => {
    const stream = createControllableStream(init.signal);
    streams.push(stream);
    return stream.response;
  };

  const a = createStreamLeader({
    tabId: "tab-a",
    endpoint: "/instant_record",
    getSyncScope: () => "s1",
    locks,
    createChannel,
    fetch: fakeFetch,
    getStreamParams: async () => ({ ready: true, cursor: 1, identity: "" }),
    applyFrames: async () => ({ applied: 0, cursor: 1, reset: false }),
  });

  a.start();
  await waitFor(() => a.isLeader() && streams.length === 1);

  a.suspend();
  await waitFor(() => !a.isLeader() && streams[0].isClosed());

  a.resume(true);
  await waitFor(() => a.isLeader() && streams.length === 2 && a.isStreamOpen());

  a.stop();
});
