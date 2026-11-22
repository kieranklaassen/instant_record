import { test } from "node:test";
import assert from "node:assert/strict";
import { isLocalUrl, resolveServerRequest, serverRoot } from "./server-request.js";

test("serverRoot strips default and custom mount paths cleanly", () => {
  assert.equal(serverRoot("/instant_record", "/instant_record"), "");
  assert.equal(serverRoot("/sync", "/sync"), "");
  assert.equal(serverRoot("http://localhost:3000/instant_record", "/instant_record"), "http://localhost:3000");
  assert.equal(serverRoot("http://localhost:3000/sync/", "/sync"), "http://localhost:3000");
  assert.equal(serverRoot("http://localhost:3000/api/sync", "/sync"), "http://localhost:3000/api");
});

test("resolveServerRequest accepts any consumer path and strips instant_record_network", () => {
  assert.equal(
    resolveServerRequest("/sessions?instant_record_network=1", "https://app.example"),
    "/sessions",
  );
  assert.equal(
    resolveServerRequest("/billing/checkout?plan=pro&instant_record_network=1", "https://app.example"),
    "/billing/checkout?plan=pro",
  );
});

test("resolveServerRequest rejects protocol-relative and cross-origin paths", () => {
  assert.throws(() => resolveServerRequest("//evil.test/steal", "https://app.example"));
  assert.throws(() => resolveServerRequest("https://evil.test/steal", "https://app.example"));
  assert.throws(() => resolveServerRequest("/\\evil.test/steal", "https://app.example"));
  assert.throws(() => resolveServerRequest("", "https://app.example"));
});

test("isLocalUrl routes app pages locally and passes static, release, service-worker, and sync paths to network", () => {
  const origin = "https://app.example";
  const u = (p) => new URL(p, origin);

  assert.equal(isLocalUrl(u("/issues"), origin, "/instant_record"), true);
  assert.equal(isLocalUrl(u("/issues/123"), origin, "/sync"), true);
  assert.equal(isLocalUrl(u("/sync_notes"), origin, "/sync"), true);

  assert.equal(isLocalUrl(u("/service-worker.js"), origin, "/instant_record"), false);
  assert.equal(isLocalUrl(u("/instant-record-release.json"), origin, "/instant_record"), false);
  assert.equal(isLocalUrl(u("/assets/application.css"), origin, "/instant_record"), false);
  assert.equal(isLocalUrl(u("/harness/worker-abc.js"), origin, "/instant_record"), false);
  assert.equal(isLocalUrl(u("/app-deadbeef.wasm"), origin, "/instant_record"), false);

  assert.equal(isLocalUrl(u("/instant_record/bootstrap"), origin, "/instant_record"), false);
  assert.equal(isLocalUrl(u("/instant_record/files/Recording/1"), origin, "/instant_record"), false);
  assert.equal(isLocalUrl(u("/sync/files/Recording/1"), origin, "/sync"), false);
  assert.equal(isLocalUrl(u("/sync/mutations"), origin, "/sync"), false);
  assert.equal(isLocalUrl(new URL("https://api.example/issues"), origin, "/instant_record"), false);
});
