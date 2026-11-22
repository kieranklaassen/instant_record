import assert from "node:assert/strict";
import { test } from "node:test";
import { isLocalRoute, isServerAllowed, parseManifest } from "./manifest.js";

const demoManifest = parseManifest(JSON.stringify({
  schema_version: 1,
  mode: "island",
  island: null,
  models: [
    { name: "Message", sync_window: { limit: 50, partition_by: "channel_id" }, sync_scope: null },
    { name: "AssistantChat", sync_window: null, sync_scope: { column: "visitor_id", policy: false } },
  ],
  local_routes: [
    { method: "GET", path: "/", controller: "home", action: "index" },
    { method: "GET", path: "/todo", controller: "todo/issues", action: "index" },
    { method: "POST", path: "/todo/issues", controller: "todo/issues", action: "create" },
    { method: "DELETE", path: "/todo/issues/:id", controller: "todo/issues", action: "destroy" },
    { method: "GET", path: "/slack/channels/:id", controller: "slack/channels", action: "show" },
    { method: "GET", path: "/receipts/probe", controller: "receipts", action: "probe" },
  ],
  server_routes: [
    { method: "POST", path: "/slack/reset", controller: "slack/resets", action: "create" },
    { method: "GET", path: "/auth/session", controller: "auth/sessions", action: "show" },
    { method: "POST", path: "/auth/session", controller: "auth/sessions", action: "create" },
    { method: "POST", path: "/auth/session/sign_out", controller: "auth/sessions", action: "destroy" },
    { method: "POST", path: "/email/sync/:member/:inbox/incoming", controller: "email/sync", action: "incoming" },
    { method: "GET", path: "/receipts/probe", controller: "receipts", action: "probe" },
  ],
}));

test("island mode matches local routes by path and HTTP method, leaving server routes to the network", () => {
  assert.equal(isLocalRoute(demoManifest, "/", "GET"), true);
  assert.equal(isLocalRoute(demoManifest, "/todo", "GET"), true);
  assert.equal(isLocalRoute(demoManifest, "/todo/issues/abc-123", "DELETE"), true);
  // Rails forms submit DELETE via POST + _method=delete
  assert.equal(isLocalRoute(demoManifest, "/todo/issues/abc-123", "POST"), true);
  // GET /todo/issues/:id is not in local_routes; only DELETE is
  assert.equal(isLocalRoute(demoManifest, "/todo/issues/abc-123", "GET"), false);
  assert.equal(isLocalRoute(demoManifest, "/slack/channels/channel-general", "GET"), true);
  assert.equal(isLocalRoute(demoManifest, "/slack/channels/channel-general", "DELETE"), false);
  assert.equal(isLocalRoute(demoManifest, "/admin/billing", "GET"), false);
  assert.equal(isLocalRoute(demoManifest, "/auth/session", "GET"), false);
});

test("relative patterns and inline param segments normalize and match cleanly", () => {
  const custom = parseManifest({
    mode: "island",
    local_routes: [
      { method: "GET", path: "items/p-:id.json" },
    ],
    server_routes: [
      { method: "POST", path: "custom/export" },
    ],
  });
  assert.equal(isLocalRoute(custom, "/items/p-42.json", "GET"), true);
  assert.equal(isLocalRoute(custom, "/items/other", "GET"), false);
  assert.equal(isServerAllowed(custom, "POST", "/custom/export", "https://api.example.test/sync"), true);
  assert.equal(isServerAllowed(custom, "GET", "/sync/bootstrap", "https://api.example.test/sync"), true);
});

test("serverRequest authorization uses manifest server_routes and sync endpoint", () => {
  assert.equal(isServerAllowed(demoManifest, "GET", "/auth/session"), true);
  assert.equal(isServerAllowed(demoManifest, "POST", "/auth/session"), true);
  assert.equal(isServerAllowed(demoManifest, "POST", "/auth/session/sign_out"), true);
  assert.equal(isServerAllowed(demoManifest, "POST", "/slack/reset"), true);
  assert.equal(isServerAllowed(demoManifest, "GET", "/slack/reset"), false);
  assert.equal(isServerAllowed(demoManifest, "GET", "/receipts/probe"), true);
  assert.equal(isServerAllowed(demoManifest, "POST", "/email/sync/maya/support/incoming"), true);
  assert.equal(isServerAllowed(demoManifest, "GET", "/instant_record/bootstrap", "http://127.0.0.1:3210/instant_record"), true);
  assert.equal(isServerAllowed(demoManifest, "POST", "/instant_record/mutations", "http://127.0.0.1:3210/instant_record"), true);
  assert.equal(isServerAllowed(demoManifest, "POST", "/admin/drop_database"), false);
});

test("full mode falls back to allowing all local paths when no local_first island is declared", () => {
  const full = parseManifest("");
  assert.equal(full.mode, "full");
  assert.equal(isLocalRoute(full, "/anything/here"), true);
  assert.equal(isServerAllowed(full, "GET", "/instant_record/bootstrap"), true);
  assert.equal(isServerAllowed(full, "POST", "/unknown"), false);
});
