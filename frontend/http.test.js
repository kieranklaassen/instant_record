import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { test } from "node:test"

const stubInertiaUrl = "data:text/javascript," + encodeURIComponent(
  "export class HttpResponseError extends Error { constructor(message, response, url) { super(message); this.response = response; this.url = url } }",
)
registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier === "@inertiajs/core") return { url: stubInertiaUrl, shortCircuit: true }
    return nextResolve(specifier, context)
  },
})

const { localHttpClient } = await import("./http.js")

async function withMockBrowser(handler, fn) {
  const previousWindow = globalThis.window
  const previousFetch = globalThis.fetch
  const calls = []
  globalThis.window = { location: { href: "http://localhost/email?member=maya&inbox=support" } }
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), init })
    return handler(url, init)
  }
  try {
    return await fn(calls)
  } finally {
    globalThis.window = previousWindow
    globalThis.fetch = previousFetch
  }
}

test("localHttpClient forwards real Inertia headers without _inertia or _only query params", async () => {
  await withMockBrowser(
    () => new Response(JSON.stringify({ component: "Email/Inbox", props: { mail: {} } }), {
      status: 200,
      headers: { "X-Inertia": "true", "Content-Type": "application/json; charset=utf-8", Vary: "X-Inertia" },
    }),
    async (calls) => {
      const reply = await localHttpClient.request({
        method: "get",
        url: "/email",
        params: { member: "maya", inbox: "support" },
        headers: {
          "X-Inertia": "true",
          "X-Inertia-Partial-Component": "Email/Inbox",
          "X-Inertia-Partial-Data": "mail",
          Accept: "text/html, application/xhtml+xml",
          "X-Requested-With": "XMLHttpRequest",
        },
      })

      assert.equal(calls.length, 1)
      const requested = new URL(calls[0].url)
      assert.equal(requested.pathname, "/email")
      assert.equal(requested.searchParams.get("_inertia"), null)
      assert.equal(requested.searchParams.get("_only"), null)
      assert.equal(calls[0].init.method, "GET")
      assert.deepEqual(calls[0].init.headers, {
        "X-Inertia": "true",
        "X-Inertia-Partial-Component": "Email/Inbox",
        "X-Inertia-Partial-Data": "mail",
        Accept: "text/html, application/xhtml+xml",
        "X-Requested-With": "XMLHttpRequest",
      })
      assert.equal(reply.status, 200)
      assert.equal(reply.headers["x-inertia"], "true")
      assert.equal(reply.headers["vary"], "X-Inertia")
      assert.match(reply.headers["content-type"], /application\/json/)
    },
  )
})

test("localHttpClient sends a single POST with form body, drops conflicting Content-Type, and returns server response", async () => {
  await withMockBrowser(
    () => new Response(JSON.stringify({ component: "Email/Inbox", props: {} }), {
      status: 200,
      headers: { "X-Inertia": "true", "Content-Type": "application/json" },
    }),
    async (calls) => {
      const reply = await localHttpClient.request({
        method: "patch",
        url: "/email",
        data: { member: "maya", kind: "read", parent_id: "m1" },
        headers: { "X-Inertia": "true", "Content-Type": "application/json" },
      })

      assert.equal(calls.length, 1)
      assert.equal(calls[0].init.method, "POST")
      assert.equal(calls[0].init.headers["X-Inertia"], "true")
      assert.equal(calls[0].init.headers["Content-Type"], undefined)
      assert.ok(calls[0].init.body instanceof URLSearchParams)
      assert.equal(calls[0].init.body.get("_method"), "PATCH")
      assert.equal(calls[0].init.body.get("parent_id"), "m1")
      assert.equal(reply.status, 200)
    },
  )
})

test("localHttpClient throws HttpResponseError carrying real status, data, and headers on >=400", async () => {
  await withMockBrowser(
    () => new Response("", { status: 409, headers: { "X-Inertia-Location": "/email" } }),
    async () => {
      await assert.rejects(
        () => localHttpClient.request({ method: "GET", url: "/email", headers: { "X-Inertia": "true" } }),
        (error) => {
          assert.equal(error.response.status, 409)
          assert.equal(error.response.headers["x-inertia-location"], "/email")
          return true
        },
      )
    },
  )
})
