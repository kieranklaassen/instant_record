import assert from "node:assert/strict";
import { test } from "node:test";
import { runDrain } from "./sync-drain.js";

// In-memory harness mirroring worker.js's snapshot revision + host bridge.
function createHarness({ batchSize = 3, bootstrapped = true, max5xxRetries = 3 } = {}) {
  let snapshotRevision = 0;
  let savedCount = 0;
  let cursor = bootstrapped ? 10 : 0;
  let isBootstrapped = bootstrapped;
  let outbox = [];
  let adaptiveLimit = null;
  const retryCounts = new Map();
  const quarantined = [];
  const sentCounts = new Map();
  const scheduledDelays = [];
  const notifications = [];

  function effectiveLimit() {
    return adaptiveLimit ? Math.min(batchSize, adaptiveLimit) : batchSize;
  }

  function addLocalEdit(id, recordId = id) {
    outbox.push({ id, record_id: recordId });
    snapshotRevision++;
  }

  const host = {
    syncPlan() {
      const batch = outbox.slice(0, effectiveLimit());
      return {
        push: batch.length ? JSON.stringify({ mutations: batch }) : "",
        mutation_ids: batch.map(m => m.id),
        bootstrap: !isBootstrapped,
      };
    },
    syncState() {
      return { bootstrapped: isBootstrapped, cursor, pending: outbox.length };
    },
    applySync(_endpoint, { push, bootstrap }) {
      let changed = false;
      let progressed = false;
      let failed = false;
      let quarantinedNow = 0;

      if (push) {
        if (push.status >= 200 && push.status < 300) {
          const parsed = JSON.parse(push.body);
          const resolvedIds = new Set((parsed.results || []).map(r => r.mutation_id));
          const before = outbox.length;
          outbox = outbox.filter(m => !resolvedIds.has(m.id));
          for (const id of resolvedIds) retryCounts.delete(id);
          const resolved = before - outbox.length;
          if (resolved > 0) changed = true;
          const anySentStillQueued = push.mutation_ids.some(id => outbox.some(m => m.id === id));
          if (resolved > 0 || !anySentStillQueued) progressed = true;
          if (outbox.length === 0) adaptiveLimit = null;
        } else if (push.status >= 500 && push.status < 600) {
          const live = push.mutation_ids.filter(id => outbox.some(m => m.id === id));
          if (live.length > 1) {
            adaptiveLimit = Math.max(Math.floor(live.length / 2), 1);
            failed = true;
          } else if (live.length === 1) {
            const id = live[0];
            const attempts = (retryCounts.get(id) || 0) + 1;
            if (attempts >= max5xxRetries) {
              outbox = outbox.filter(m => m.id !== id);
              retryCounts.delete(id);
              quarantined.push(id);
              adaptiveLimit = null;
              quarantinedNow = 1;
              changed = true;
              progressed = true;
            } else {
              retryCounts.set(id, attempts);
              failed = true;
            }
          }
        } else {
          failed = true;
        }
      }

      if (bootstrap && !isBootstrapped && bootstrap.status >= 200 && bootstrap.status < 300) {
        isBootstrapped = true;
        cursor = JSON.parse(bootstrap.body).cursor ?? 1;
        changed = true;
        progressed = true;
      }

      return {
        changed,
        pending: outbox.length,
        cursor,
        progressed,
        failed,
        quarantined: quarantinedNow,
        notified: changed,
        changes: null,
      };
    },
  };

  async function withSnapshot(_mode, op) {
    return op(() => {
      savedCount++;
      snapshotRevision++;
    });
  }

  return {
    addLocalEdit,
    host,
    withSnapshot,
    sentCounts,
    scheduledDelays,
    notifications,
    quarantined,
    get outbox() { return outbox; },
    get snapshotRevision() { return snapshotRevision; },
    get savedCount() { return savedCount; },
    retryState: { baseMs: 500, capMs: 10000, delayMs: 500 },
  };
}

test("rapid local clicks during in-flight POST merge acks without discarding or livelocking", async () => {
  const h = createHarness({ batchSize: 3 });
  h.addLocalEdit("m1");
  h.addLocalEdit("m2");

  let nextId = 3;
  const fetchReply = async (method, path, body) => {
    assert.equal(method, "POST");
    assert.equal(path, "/mutations");
    const parsed = JSON.parse(body);
    for (const m of parsed.mutations) {
      h.sentCounts.set(m.id, (h.sentCounts.get(m.id) || 0) + 1);
    }
    // Simulate rapid user clicks bumping snapshotRevision while POST is in flight!
    if (nextId <= 8) {
      h.addLocalEdit(`m${nextId++}`);
      h.addLocalEdit(`m${nextId++}`);
    }
    return {
      status: 200,
      text: JSON.stringify({
        results: parsed.mutations.map(m => ({ mutation_id: m.id, status: "applied", version: 1 })),
      }),
    };
  };

  let rounds = 0;
  while (h.outbox.length > 0 && rounds < 10) {
    rounds++;
    await runDrain({
      withSnapshot: h.withSnapshot,
      fetchReply,
      getHost: () => h.host,
      syncEndpoint: "/instant_record",
      onRecordsChanged: c => h.notifications.push(c),
      scheduleRetry: delay => h.scheduledDelays.push(delay),
      retryState: h.retryState,
    });
  }

  assert.equal(h.outbox.length, 0, "all rapid clicks must drain to zero");
  assert.equal(h.sentCounts.size, 8);
  for (const [id, count] of h.sentCounts) {
    assert.equal(count, 1, `mutation ${id} must not be redundantly replayed`);
  }
  assert.ok(h.scheduledDelays.every(d => d === 0), "healthy chunk continuation must not apply backoff");
  assert.equal(h.retryState.delayMs, 500);
});

test("5xx poison pill bisects, backs off while failing, and immediately resumes after quarantine", async () => {
  const h = createHarness({ batchSize: 4, max5xxRetries: 2 });
  h.addLocalEdit("good-1");
  h.addLocalEdit("poison");
  h.addLocalEdit("good-2");
  h.addLocalEdit("good-3");

  const fetchReply = async (_method, _path, body) => {
    const parsed = JSON.parse(body);
    if (parsed.mutations.some(m => m.id === "poison")) {
      return { status: 500, text: "Internal Server Error" };
    }
    return {
      status: 200,
      text: JSON.stringify({
        results: parsed.mutations.map(m => ({ mutation_id: m.id, status: "applied", version: 1 })),
      }),
    };
  };

  let rounds = 0;
  while (h.outbox.length > 0 && rounds < 12) {
    rounds++;
    await runDrain({
      withSnapshot: h.withSnapshot,
      fetchReply,
      getHost: () => h.host,
      syncEndpoint: "/instant_record",
      scheduleRetry: delay => h.scheduledDelays.push(delay),
      retryState: h.retryState,
    });
  }

  assert.equal(h.outbox.length, 0, "queue must completely drain past the poison pill");
  assert.deepEqual(h.quarantined, ["poison"], "only the poison pill is quarantined");
  assert.ok(h.scheduledDelays.some(d => d >= 500), "5xx failures back off before quarantine");
  assert.equal(h.scheduledDelays.at(-1), 0, "quarantine immediately schedules next drain with 0ms delay");
});

test("offline response applies exponential backoff and keeps pending mutations intact", async () => {
  const h = createHarness({ batchSize: 4 });
  h.addLocalEdit("offline-1");

  const fetchReply = async () => ({ status: 0, text: "" });

  await runDrain({
    withSnapshot: h.withSnapshot,
    fetchReply,
    getHost: () => h.host,
    syncEndpoint: "/instant_record",
    scheduleRetry: delay => h.scheduledDelays.push(delay),
    retryState: h.retryState,
  });
  await runDrain({
    withSnapshot: h.withSnapshot,
    fetchReply,
    getHost: () => h.host,
    syncEndpoint: "/instant_record",
    scheduleRetry: delay => h.scheduledDelays.push(delay),
    retryState: h.retryState,
  });

  assert.equal(h.outbox.length, 1);
  assert.deepEqual(h.quarantined, []);
  assert.deepEqual(h.scheduledDelays, [500, 1000]);
  assert.equal(h.retryState.delayMs, 2000);
});
