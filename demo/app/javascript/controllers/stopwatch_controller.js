import { Controller } from "@hotwired/stimulus"

// The stopwatch on each of the four todo apps (/plain, /hotwire, /inertia,
// /instant). It is the same code on all four and knows nothing about how a
// page updates: it starts at the input event (a submit, a tick, a click on a
// row's button) and stops in the first frame where the list is different, so
// it times what a person waits for, whether that was a page, a stream, a
// React render or a local write.
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

const start = (action, at = now()) => {
  const pending = read("pending", null)
  if (pending && at - pending.at < 1000) return // one gesture, several events
  write("pending", { action, at, before: signature() })
}

const stop = () => {
  const pending = read("pending", null)
  if (!pending || !list() || signature() === pending.before) return
  write("pending", null)
  // The frame that holds the change, and then the paint of it.
  requestAnimationFrame(() => setTimeout(() => {
    const time = { action: pending.action, at: pending.at, ms: Math.round(now() - pending.at) }
    const history = [...read("history", []), time].slice(-60)
    write("history", history)
    show(history)
    if (window.parent !== window) window.parent.postMessage({ type: "four.time", way: way(), ...time }, "*")
  }, 0))
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
    ? `${last.action} ${last.ms} ms · median ${median(history.map((time) => time.ms))} ms of ${history.length}`
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
