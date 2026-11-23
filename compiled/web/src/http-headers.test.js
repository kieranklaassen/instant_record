import assert from "node:assert/strict";
import { test } from "node:test";
import { buildHttpRequest, extractHeaders, headerValue, redirectHeaders } from "./http-headers.js";

const decoder = new TextDecoder();

test("buildHttpRequest forwards Inertia, Turbo, Accept, X-Requested-With, and Referer headers", () => {
  const bytes = buildHttpRequest("GET", "/email?member=maya&inbox=support", {
    headers: {
      "X-Inertia": "true",
      "X-Inertia-Partial-Component": "Email/Inbox",
      "X-Inertia-Partial-Data": "mail,thread",
      "Turbo-Frame": "inbox_frame",
      Accept: "text/html, application/xhtml+xml",
      "X-Requested-With": "XMLHttpRequest",
      Referer: "http://127.0.0.1:4173/email?member=maya&inbox=support",
      Host: "127.0.0.1:4173",
    },
  });

  const text = decoder.decode(bytes);
  assert.ok(text.startsWith("GET /email?member=maya&inbox=support HTTP/1.1\r\nHost: 127.0.0.1:4173\r\n"));
  assert.ok(text.includes("X-Inertia: true\r\n"));
  assert.ok(text.includes("X-Inertia-Partial-Component: Email/Inbox\r\n"));
  assert.ok(text.includes("X-Inertia-Partial-Data: mail,thread\r\n"));
  assert.ok(text.includes("Turbo-Frame: inbox_frame\r\n"));
  assert.ok(text.includes("Accept: text/html, application/xhtml+xml\r\n"));
  assert.ok(text.includes("X-Requested-With: XMLHttpRequest\r\n"));
  assert.ok(text.includes("Referer: http://127.0.0.1:4173/email?member=maya&inbox=support\r\n"));
  assert.ok(text.endsWith("\r\n\r\n"));
});

test("buildHttpRequest sanitizes CRLF, drops invalid header names, and frames UTF-8 headers accurately", () => {
  const bytes = buildHttpRequest("POST", "/email", {
    body: "subject=caf%C3%A9",
    headers: {
      "X-Inertia": "true\r\nEvil: injected",
      "Bad Header Name": "dropped",
      "Content-Length": "9999",
      "X-Note": "café",
    },
  });

  const text = decoder.decode(bytes);
  assert.ok(!text.includes("\r\nEvil: injected\r\n"));
  assert.ok(text.includes("X-Inertia: true Evil: injected\r\n"));
  assert.ok(!text.includes("Bad Header Name"));
  assert.ok(text.includes("Content-Type: application/x-www-form-urlencoded\r\n"));
  assert.ok(text.includes("Content-Length: 17\r\n"));
  assert.ok(text.endsWith("\r\n\r\nsubject=caf%C3%A9"));
});

test("buildHttpRequest accepts Headers instances, merges cookies safely, and applies _method override", () => {
  const headers = new Headers([
    ["X-Inertia", "true"],
    ["Content-Type", "application/x-www-form-urlencoded"],
  ]);
  const cookies = new Map([["_session", "abc"]]);
  const bytes = buildHttpRequest("POST", "/items/1", {
    body: "_method=patch&title=hi",
    headers,
    cookies,
  });

  const text = decoder.decode(bytes);
  assert.ok(text.startsWith("PATCH /items/1 HTTP/1.1\r\nHost: localhost\r\nCookie: _session=abc\r\n"));
  assert.ok(text.includes("x-inertia: true\r\n"));
  assert.ok(text.endsWith("\r\n\r\n_method=patch&title=hi"));
});

test("redirectHeaders keeps Inertia/Turbo/Accept/Referer headers and drops body framing headers", () => {
  const forwarded = redirectHeaders({
    "X-Inertia": "true",
    "X-Inertia-Partial-Data": "mail",
    "Turbo-Frame": "modal",
    Accept: "text/html",
    "X-Requested-With": "XMLHttpRequest",
    Referer: "http://localhost/email",
    "Content-Type": "application/x-www-form-urlencoded",
    "Content-Length": "42",
  });

  assert.deepEqual(forwarded, {
    "X-Inertia": "true",
    "X-Inertia-Partial-Data": "mail",
    "Turbo-Frame": "modal",
    Accept: "text/html",
    "X-Requested-With": "XMLHttpRequest",
    Referer: "http://localhost/email",
  });
  assert.equal(headerValue(new Headers({ "X-Inertia": "true" }), "x-inertia"), "true");
  assert.deepEqual(extractHeaders([["Accept", "application/json"]]), { Accept: "application/json" });
});
