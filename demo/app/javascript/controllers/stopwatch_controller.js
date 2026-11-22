import { Controller } from "@hotwired/stimulus"

// The stopwatch on each of the four todo apps (/plain, /hotwire, /inertia,
// /instant). It is the same code on all four and knows nothing about how a
// page updates: it starts at the input event (a submit, a tick, a click on a
// row's button) and stops in the first frame where the list is different, so
// it times what a person waits for, whether that was a page, a stream, a
// React render or a local write. Beside that it keeps when the write's answer
// reached the page, which says how long the screen and the truth were apart.
//
// The list is the element this controller is on. A row is told from another
// by its id (or data-id) and its class, so adding, ticking and deleting each
// change the list. The pending start is kept in sessionStorage, because a
// page that answers with a whole new document forgets everything else.
const way = () => location.pathname.split("/")[1]
const key = (name) => `four.${name}:${way()}`
const now = () => performance.timeOrigin + performance.now()
const list = () => document.querySelector('[data-controller~="stopwatch"]')
const signature = () =>
  [...(list()?.children ?? [])].map((row) => `${row.id || row.dataset.id}:${row.className}`).join("|")

const read = (name, fallback) => {
  try { return JSON.parse(sessionStorage.getItem(key(name))) ?? fallback } catch { return fallback }
}
const write = (name, value) => {
  try { sessionStorage.setItem(key(name), JSON.stringify(value)) } catch {}
}

// The press being timed. `answered` is set when the page has the answer to its
// write in hand: from the server for three of the apps, from the app in this
// browser for the fourth.
let open = null

const start = (action, at = now()) => {
  const pending = read("pending", null)
  if (pending && at - pending.at < 1000) return // one gesture, several events
  open = { at, answered: null }
  write("pending", { action, at, before: signature() })
}

const stop = () => {
  const pending = read("pending", null)
  if (!pending || !list() || signature() === pending.before) return
  write("pending", null)
  // The frame that holds the change, and then the paint of it.
  requestAnimationFrame(() => setTimeout(() => {
    const time = { action: pending.action, at: pending.at, ms: Math.round(now() - pending.at) }
    if (open?.at === pending.at && open.answered !== null) time.answered = open.answered
    record([...read("history", []), time].slice(-60))
    tell(time)
  }, 0))
}

// A write's answer arrived. It may come before the change is shown (the page
// waited for it) or after (the page drew first).
const answer = () => {
  if (!open || open.answered !== null) return
  open.answered = Math.round((now() - open.at) * 10) / 10
  const history = read("history", [])
  const time = history.find((each) => each.at === open.at)
  if (!time) return // not shown yet: stop() picks it up
  time.answered = open.answered
  record(history)
  tell(time)
}

const record = (history) => {
  write("history", history)
  show(history)
}

const tell = (time) => {
  if (window.parent !== window) window.parent.postMessage({ type: "four.time", way: way(), ...time }, "*")
}

// Every way a page sends a write: fetch (Turbo, and the compiled runtime's own
// fetch underneath it) and XMLHttpRequest (Inertia).
const watchWrites = () => {
  const fetchWas = window.fetch
  window.fetch = async (input, init) => {
    const method = (init?.method || input?.method || "GET").toUpperCase()
    const response = await fetchWas(input, init)
    if (method !== "GET") answer()
    return response
  }
  const openWas = XMLHttpRequest.prototype.open
  XMLHttpRequest.prototype.open = function (method, ...rest) {
    if (String(method).toUpperCase() !== "GET") this.addEventListener("load", answer) // not loadend: a request given up has no answer
    return openWas.call(this, method, ...rest)
  }
}

const median = (values) => {
  const sorted = [...values].sort((a, b) => a - b)
  return sorted.length ? sorted[Math.floor((sorted.length - 1) / 2)] : null
}

const show = (history) => {
  window.__stopwatch = { history, last: history.at(-1) ?? null }
  let clock = document.querySelector(".four-clock")
  if (!clock) {
    clock = document.createElement("output")
    clock.className = "four-clock"
    document.body.append(clock)
  }
  const last = history.at(-1)
  clock.textContent = last
    ? `${last.action}: shown ${last.ms} ms${last.answered == null ? "" : `, answered ${last.answered} ms`} · median ${median(history.map((time) => time.ms))} ms of ${history.length}`
    : "no action timed yet"
}

const actionOf = (event) => {
  const target = event.target
  if (!target.closest?.(".four")) return null
  if (event.type === "submit") {
    if (target.querySelector("input[type='text']")) return "add"
    return target.querySelector("input[type='checkbox']") ? "toggle" : "delete"
  }
  // A click, not a change: React has already drawn the tick by the time change fires.
  if (target.matches("input[type='checkbox']")) return "toggle"
  return target.closest("li") && target.closest("button") ? "delete" : null
}

// Lets the side-by-side page press the same thing in all four at once.
const act = ({ action, title }) => {
  const root = document.querySelector(".four")
  if (!root) return
  if (action === "add") {
    const input = root.querySelector("input[type='text']")
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set.call(input, title)
    input.dispatchEvent(new Event("input", { bubbles: true }))
    requestAnimationFrame(() => input.form.requestSubmit())
  } else {
    list()?.querySelector(action === "toggle" ? "input[type='checkbox']" : "li button")?.click()
  }
}

let armed = false
const arm = () => {
  if (armed) return
  armed = true
  watchWrites()
  for (const type of ["submit", "click"]) {
    document.addEventListener(type, (event) => {
      const action = actionOf(event)
      if (action) start(action, performance.timeOrigin + event.timeStamp)
    }, true)
  }
  new MutationObserver(stop).observe(document.documentElement, {
    subtree: true, childList: true, attributes: true, attributeFilter: ["class", "id", "data-id"],
  })
  window.addEventListener("message", (event) => {
    if (event.data?.type === "four.do") act(event.data)
    if (event.data?.type === "four.clear") { write("history", []); show([]) }
  })
  if (window.parent !== window) document.documentElement.classList.add("framed")
}

export default class extends Controller {
  connect() {
    arm()
    show(read("history", []))
    stop()
  }
}
