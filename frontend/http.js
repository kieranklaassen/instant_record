// An HTTP client for Inertia that the local database answers.
//
// In the compiled runtime the app's controllers run in a worker in this tab.
// The page's `fetch` reaches them with full HTTP headers (X-Inertia,
// X-Inertia-Partial-Component, X-Inertia-Partial-Data, Accept, Referer, ...);
// XMLHttpRequest, which Inertia uses by default, does not. So this client sends
// each Inertia request through `fetch` with its real headers and lets the
// worker follow redirects like a browser.
import { HttpResponseError } from "@inertiajs/core"

const formBody = (data, verb) => {
  const fields = new URLSearchParams()
  const entries = data instanceof FormData ? [...data.entries()] : Object.entries(data || {})
  for (const [key, value] of entries) if (value !== null && value !== undefined) fields.append(key, String(value))
  if (verb !== "POST") fields.set("_method", verb)
  return fields
}

const failure = (status, url, data = "", headers = {}) =>
  new HttpResponseError(`Request failed with status ${status}`, { status, data, headers }, url)

const responseHeaders = (headers) => {
  const result = {}
  if (headers && typeof headers.forEach === "function") {
    headers.forEach((value, key) => { result[key.toLowerCase()] = value })
  }
  return result
}

const xsrf = () => decodeURIComponent(document.cookie.match(/(?:^|; )XSRF-TOKEN=([^;]*)/)?.[1] || "")

// A write that visits nothing: a form post that neither follows the app's
// redirect nor reloads a prop. A page sending several writes in a row sends
// each this way and reloads its props once at the end, where `router.post`
// would answer every one with the whole page.
//
// It reaches Rails with the token Inertia's own requests carry. Beside a
// local database it is the page's own `fetch`, which the worker answers.
// `keepalive` lets the browser finish the request after the page is gone.
export async function write(url, data, { keepalive = false } = {}) {
  const headers = { "X-Requested-With": "XMLHttpRequest" }
  const token = xsrf()
  if (token) headers["X-XSRF-TOKEN"] = token
  const sent = await fetch(new URL(url, window.location.href), {
    method: "POST", body: formBody(data, "POST"), headers, redirect: "manual", keepalive, credentials: "same-origin",
  })
  // A redirect not followed is the app saying the write was taken.
  if (!sent.ok && sent.type !== "opaqueredirect") throw failure(sent.status, url)
}

export const localHttpClient = {
  async request({ method, url, data, params, headers, signal }) {
    const target = new URL(url, window.location.href)
    for (const [key, value] of Object.entries(params || {})) target.searchParams.set(key, String(value))
    const verb = method.toUpperCase()
    const requestHeaders = {}
    for (const [key, value] of Object.entries(headers || {})) {
      if (value === null || value === undefined) continue
      if (verb !== "GET" && verb !== "HEAD" && key.toLowerCase() === "content-type") continue
      requestHeaders[key] = String(value)
    }

    const init = {
      method: verb === "GET" || verb === "HEAD" ? verb : "POST",
      headers: requestHeaders,
      signal,
    }
    if (verb !== "GET" && verb !== "HEAD") init.body = formBody(data, verb)

    const response = await fetch(target, init)
    const text = await response.text()
    const replyHeaders = responseHeaders(response.headers)
    if (!response.ok) throw failure(response.status, url, text, replyHeaders)
    return { status: response.status, data: text, headers: replyHeaders }
  },
}
