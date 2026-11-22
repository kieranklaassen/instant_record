import assert from "node:assert/strict";
import { test } from "node:test";
import { aggregateSimulations, createLeaderCoordinator } from "./leader-election.js";

// Deterministic in-memory Web Locks + BroadcastChannel bus for multi-worker tests.
function createClusterBus() {
  const held = new Map(); // name -> { release }
  const queues = new Map(); // name -> [{ callback, resolve, reject }]
  const channels = new Map(); // name -> Set<channel>

  function grantNext(name) {
    if (held.has(name)) return;
    const queue = queues.get(name);
    if (!queue || queue.length === 0) return;
    const waiter = queue.shift();
    held.set(name, { name });
    Promise.resolve()
      .then(() => waiter.callback({ name }))
      .then(
        value => {
          held.delete(name);
          grantNext(name);
          waiter.resolve(value);
        },
        error => {
          held.delete(name);
          grantNext(name);
          waiter.reject(error);
        },
      );
  }

  const locks = {
    request(name, optionsOrCb, maybeCb) {
      const options = typeof optionsOrCb === "function" ? {} : optionsOrCb;
      const callback = typeof optionsOrCb === "function" ? optionsOrCb : maybeCb;
      if (options.ifAvailable) {
        if (held.has(name)) return Promise.resolve().then(() => callback(null));
        held.set(name, { name });
        return Promise.resolve()
          .then(() => callback({ name }))
          .finally(() => {
            held.delete(name);
            grantNext(name);
          });
      }
      return new Promise((resolve, reject) => {
        if (!queues.has(name)) queues.set(name, []);
        queues.get(name).push({ callback, resolve, reject });
        grantNext(name);
      });
    },
    async query() {
      await new Promise(resolve => setTimeout(resolve, 0));
      return { held: [...held.values()], pending: [] };
    },
  };

  function createChannel(name) {
    if (!channels.has(name)) channels.set(name, new Set());
    const peers = channels.get(name);
    let closed = false;
    const channel = {
      onmessage: null,
      postMessage(data) {
        if (closed) return;
        const cloned = structuredClone(data);
        for (const other of [...peers]) {
          if (other === channel) continue;
          queueMicrotask(() => {
            if (other.onmessage) other.onmessage({ data: structuredClone(cloned) });
          });
        }
      },
      close() {
        if (closed) return;
        closed = true;
        peers.delete(channel);
      },
    };
    peers.add(channel);
    return channel;
  }

  return { locks, createChannel };
}

test("elects exactly one leader per scope and routes follower RPCs without booting a second host", async () => {
  const bus = createClusterBus();
  let bootCount = 0;
  const pushes = { w1: [], w2: [] };

  const makeWorker = id => createLeaderCoordinator({
    scope: "",
    workerId: id,
    locks: bus.locks,
    createChannel: bus.createChannel,
    discoveryRetryMs: 10,
    pruneIntervalMs: 0,
    onBecomeLeader: async () => {
      bootCount++;
      return { storageMode: "opfs" };
    },
    onRpc: async (method, payload, { tabId }) => {
      if (method === "write") {
        // Notify peers of local write.
        workers[id].notifyOthers(tabId, { type: "records_changed", changes: [{ type: "Issue", id: payload.id }] });
        return { ok: true, servedBy: id, from: tabId };
      }
      return { ok: true, method, servedBy: id };
    },
    onFollowerPush: msg => pushes[id].push(msg),
  });

  const workers = { w1: makeWorker("w1"), w2: makeWorker("w2") };
  const [r1, r2] = await Promise.all([workers.w1.start(), workers.w2.start()]);

  assert.equal(bootCount, 1, "only the elected leader boots AppHost");
  assert.deepEqual([r1.role, r2.role].sort(), ["follower", "leader"]);

  const follower = r1.role === "follower" ? workers.w1 : workers.w2;
  const leader = r1.role === "leader" ? workers.w1 : workers.w2;

  const reply = await follower.call("write", { id: "42" }, { idempotent: false });
  assert.equal(reply.servedBy, leader.workerId);
  assert.equal(reply.from, follower.workerId);

  // Originating follower does not receive a duplicate records_changed; leader tab does.
  await new Promise(resolve => setTimeout(resolve, 20));
  assert.equal(pushes[leader.workerId].length, 1);
  assert.equal(pushes[follower.workerId].length, 0);

  workers.w1.close();
  workers.w2.close();
});

test("distinct scopes elect independent leaders", async () => {
  const bus = createClusterBus();
  const booted = [];

  const a = createLeaderCoordinator({
    scope: "maya/support",
    workerId: "a",
    locks: bus.locks,
    createChannel: bus.createChannel,
    pruneIntervalMs: 0,
    onBecomeLeader: async () => { booted.push("maya/support"); return { storageMode: "opfs" }; },
    onRpc: async () => ({ scope: "maya/support" }),
  });
  const b = createLeaderCoordinator({
    scope: "theo/support",
    workerId: "b",
    locks: bus.locks,
    createChannel: bus.createChannel,
    pruneIntervalMs: 0,
    onBecomeLeader: async () => { booted.push("theo/support"); return { storageMode: "opfs" }; },
    onRpc: async () => ({ scope: "theo/support" }),
  });

  const [ra, rb] = await Promise.all([a.start(), b.start()]);
  assert.equal(ra.role, "leader");
  assert.equal(rb.role, "leader");
  assert.deepEqual(booted.sort(), ["maya/support", "theo/support"]);

  a.close();
  b.close();
});

test("abrupt leader crash promotes a standby follower and transparently retries in-flight follower RPCs", async () => {
  const bus = createClusterBus();
  const promoted = [];
  let stallFirstLeader = true;

  function makeWorker(id) {
    return createLeaderCoordinator({
      scope: "",
      workerId: id,
      locks: bus.locks,
      createChannel: bus.createChannel,
      discoveryRetryMs: 10,
      pruneIntervalMs: 0,
      rpcLivenessMs: 30,
      onBecomeLeader: async ({ promoted: isPromoted }) => {
        if (isPromoted) promoted.push(id);
        return { storageMode: "opfs" };
      },
      onRpc: async (method, payload) => {
        if (id === "w1" && stallFirstLeader) {
          // Simulate a leader that dies mid-request without replying.
          await new Promise(() => {});
        }
        return { handledBy: id, method, payload };
      },
    });
  }

  const w1 = makeWorker("w1");
  const w2 = makeWorker("w2");
  const w3 = makeWorker("w3");

  await w1.start();
  await Promise.all([w2.start(), w3.start()]);
  assert.equal(w1.role, "leader");
  assert.equal(w2.role, "follower");
  assert.equal(w3.role, "follower");

  // Start an idempotent read RPC from w3 while w1 is hung, then abruptly kill w1 (no leader_bye).
  const inFlight = w3.call("navigate", { path: "/todo" }, { idempotent: true });
  await new Promise(resolve => setTimeout(resolve, 15));
  w1.close({ announceBye: false });

  const reply = await inFlight;
  assert.equal(promoted.length, 1);
  assert.equal(reply.handledBy, promoted[0]);
  assert.equal(reply.payload.path, "/todo");

  w2.close();
  w3.close();
});

test("multi-tab simulation aggregation keeps leader online if any tab is online and prunes dead peers", async () => {
  assert.deepEqual(
    aggregateSimulations({ offline: false, latencyMs: 0 }, [{ offline: true, latencyMs: 2000 }]),
    { offline: false, latencyMs: 2000 },
  );
  assert.deepEqual(
    aggregateSimulations({ offline: true, latencyMs: 0 }, [{ offline: true, latencyMs: 500 }]),
    { offline: true, latencyMs: 500 },
  );

  const bus = createClusterBus();
  const transitions = [];

  const leader = createLeaderCoordinator({
    scope: "",
    workerId: "leader",
    locks: bus.locks,
    createChannel: bus.createChannel,
    discoveryRetryMs: 10,
    pruneIntervalMs: 0,
    onBecomeLeader: async () => ({ storageMode: "opfs" }),
    onRpc: async () => ({ ok: true }),
    onLeaderSimulationChange: next => transitions.push(next),
  });
  const follower = createLeaderCoordinator({
    scope: "",
    workerId: "follower",
    locks: bus.locks,
    createChannel: bus.createChannel,
    discoveryRetryMs: 10,
    pruneIntervalMs: 0,
    onBecomeLeader: async () => ({ storageMode: "opfs" }),
    onRpc: async () => ({ ok: true }),
  });

  await leader.start();
  await follower.start();

  // Leader goes offline, follower stays online -> aggregate remains online.
  leader.updateSimulation({ offline: true, latencyMs: 0 });
  assert.equal(leader.effectiveSimulation().offline, false);

  // Follower also goes offline -> aggregate goes offline.
  follower.updateSimulation({ offline: true, latencyMs: 0 });
  await new Promise(resolve => setTimeout(resolve, 20));
  assert.equal(leader.effectiveSimulation().offline, true);

  // Follower comes back online -> aggregate goes online.
  follower.updateSimulation({ offline: false, latencyMs: 0 });
  await new Promise(resolve => setTimeout(resolve, 20));
  assert.equal(leader.effectiveSimulation().offline, false);

  // Follower crashes abruptly without detach -> pruneDeadPeers detects released presence lock and leader is now offline.
  follower.close({ announceBye: false });
  await leader.pruneDeadPeers();
  assert.equal(leader.effectiveSimulation().offline, true);
  assert.ok(transitions.some(t => t.offline === true));

  leader.close();
});

test("falls back to standalone mode when navigator.locks is absent", async () => {
  const worker = createLeaderCoordinator({
    scope: "",
    workerId: "solo",
    locks: undefined,
    createChannel: () => null,
    onBecomeLeader: async () => ({ storageMode: "indexeddb" }),
    onRpc: async (method) => ({ ok: true, method }),
  });

  const started = await worker.start();
  assert.equal(started.role, "standalone");
  assert.equal(worker.role, "standalone");
  assert.deepEqual(await worker.call("ping"), { ok: true, method: "ping" });
  worker.close();
});

test("RPCs issued on a promoting follower wait until onBecomeLeader finishes mounting storage", async () => {
  const bus = createClusterBus();
  let mounted = false;

  const w1 = createLeaderCoordinator({
    scope: "",
    workerId: "w1",
    locks: bus.locks,
    createChannel: bus.createChannel,
    pruneIntervalMs: 0,
    onBecomeLeader: async () => ({ storageMode: "opfs" }),
    onRpc: async () => ({ ok: true }),
  });
  const w2 = createLeaderCoordinator({
    scope: "",
    workerId: "w2",
    locks: bus.locks,
    createChannel: bus.createChannel,
    discoveryRetryMs: 10,
    pruneIntervalMs: 0,
    onBecomeLeader: async () => {
      await new Promise(resolve => setTimeout(resolve, 40));
      mounted = true;
      return { storageMode: "opfs" };
    },
    onRpc: async () => {
      assert.equal(mounted, true, "onRpc must not execute before onBecomeLeader finishes");
      return { servedBy: "w2", mounted };
    },
  });

  await w1.start();
  await w2.start();

  // Kill leader and immediately invoke RPC on w2 while it is still promoting.
  w1.close({ announceBye: true });
  await new Promise(resolve => setTimeout(resolve, 5));
  const reply = await w2.call("read", null, { idempotent: true });
  assert.deepEqual(reply, { servedBy: "w2", mounted: true });
  w2.close();
});
