import assert from "node:assert/strict";
import { test } from "node:test";
import { createAppHostClass } from "./app-host-core.js";
import * as minimalWasi from "./wasi-minimal.js";

const AppHost = createAppHostClass(minimalWasi);

// notices() without a compiled module: only the app's answer and its change notice matter here.
function answering(body, notify = "") {
  const encoder = new TextEncoder();
  return AppHost.prototype.notices.call({
    notifyFile: { data: new Uint8Array() },
    hostDir: { contents: new Map() },
    call() {
      this.notifyFile.data = encoder.encode(notify);
      return { exit: 0, out: encoder.encode(JSON.stringify(body)), errors: [], events: [], fault: null };
    },
  });
}

test("notices keeps the list the app answered with", () => {
  const list = [{ id: "n-1", reason: "exceeds the limit" }];
  assert.deepEqual(answering({ ok: true, notices: list }).notices, list);
});

test("notices keeps that list and reports the change a retry made", () => {
  const list = [{ id: "n-2", reason: "still refused" }];
  const result = answering({ ok: true, notices: list }, "records_changed");
  assert.deepEqual(result.notices, list);
  assert.equal(result.notified, true);
});
