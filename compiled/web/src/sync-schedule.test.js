import assert from "node:assert/strict";
import { test } from "node:test";
import { nextSyncAction } from "./sync-schedule.js";

test("matured pending writes schedule an immediate drain", () => {
  assert.deepEqual(
    nextSyncAction({ pending: 2, bootstrapped: true, nextReleaseMs: 4000 }, 30),
    { kind: "immediate", delay: 30 },
  );
});

test("unbootstrapped database schedules an immediate pass even when nothing is pending", () => {
  assert.deepEqual(
    nextSyncAction({ pending: 0, bootstrapped: false, nextReleaseMs: null }, 500),
    { kind: "immediate", delay: 500 },
  );
});

test("held mutations with nothing matured schedule a held timer for nextReleaseMs", () => {
  assert.deepEqual(
    nextSyncAction({ pending: 0, bootstrapped: true, nextReleaseMs: 4850 }, 30),
    { kind: "held", delay: 4850 },
  );
});

test("negative nextReleaseMs clamps to zero", () => {
  assert.deepEqual(
    nextSyncAction({ pending: 0, bootstrapped: true, nextReleaseMs: -10 }, 30),
    { kind: "held", delay: 0 },
  );
});

test("empty outbox on a bootstrapped database stays idle", () => {
  assert.deepEqual(
    nextSyncAction({ pending: 0, bootstrapped: true, nextReleaseMs: null }, 30),
    { kind: "idle" },
  );
});
