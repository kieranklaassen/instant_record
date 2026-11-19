// An HTTP client for Inertia that the local database answers.
//
// In the compiled runtime the app's controllers run in a worker in this tab.
// The page's `fetch` reaches them; XMLHttpRequest, which Inertia uses, does
// not, and the worker's requests carry no headers. So this client sends each
// Inertia request through `fetch` and says in the address what the headers
// would have: `_inertia=1` for "answer with a page object" and `_only` for a
// partial reload's props.
//
// A write is a form post. The worker follows the app's redirect itself, so
// the client then asks for the page it is on, which is what the server does
// with `redirect_back`.
import { HttpResponseError } from "@inertiajs/core"

const header = (headers, name) =>
  Object.entries(headers || {}).find(([key]) => key.toLowerCase() === name)?.[1]

const formBody = (data, verb) => {
  const fields = new URLSearchParams()
  const entries = data instanceof FormData ? [...data.entries()] : Object.entries(data || {})
  for (const [key, value] of entries) if (value !== null && value !== undefined) fields.append(key, String(value))
  if (verb !== "POST") fields.set("_method", verb)
  return fields
}

const failure = (status, url) =>
  new HttpResponseError(`Request failed with status ${status}`, { status, data: "", headers: {} }, url)

export const localHttpClient = {
  async request({ method, url, data, params, headers, signal }) {
    const target = new URL(url, window.location.href)
    for (const [key, value] of Object.entries(params || {})) target.searchParams.set(key, String(value))
    const verb = method.toUpperCase()

    let page = target
    if (verb !== "GET") {
      const sent = await fetch(target, { method: "POST", body: formBody(data, verb), redirect: "manual", signal })
      if (!sent.ok) throw failure(sent.status, url)
      page = new URL(window.location.href)
    }

    page.searchParams.set("_inertia", "1")
    const only = header(headers, "x-inertia-partial-data")
    if (only) page.searchParams.set("_only", only)
    const response = await fetch(page, { signal })
    if (!response.ok) throw failure(response.status, url)
    return { status: 200, data: await response.text(), headers: { "x-inertia": "true", "content-type": "application/json" } }
  },
}
