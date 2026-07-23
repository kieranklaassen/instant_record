import { Controller } from "@hotwired/stimulus"

// A live view of the sync flow, always on, shared by every demo (it lives in
// the layout).
//
// Everything comes from the service worker (see rails.sw.js), which is the only
// place that sees both halves of the flow: same-origin requests the wasm VM
// serves — navigations and form posts included, which a page-side fetch wrapper
// would miss entirely — and the sync traffic Ruby's transport makes from inside
// the worker. Subscribing happens once at module load, not in connect(), so a
// Turbo visit doesn't stack a second listener.

const MAX_ENTRIES = 150
const SLOW_LATENCY_MS = 2000
const PULSE_MS = 600

const entries = []
const listeners = new Set()

// The simulation switches have to outlive the page they act on: Turbo replaces
// <body> on a visit and the Todo demo posts forms the old-fashioned way, so the
// checkboxes would otherwise disagree with what the worker is still doing.
const UI_KEY = "instant_record.inspector"

const storedUi = () => {
  try {
    return JSON.parse(sessionStorage.getItem(UI_KEY)) || {}
  } catch {
    return {}
  }
}

const ui = { offline: false, slow: false, ...storedUi() }

const saveUi = () => {
  try {
    sessionStorage.setItem(UI_KEY, JSON.stringify(ui))
  } catch {
    // Private mode or a full quota: the switches still work for this page.
  }
}

// Whether the change stream is currently held open. The worker stamps this on
// its stream reports, so the map can show a live connection rather than only the
// moment data crossed it.
let streamOpen = false

const record = (entry) => {
  if (typeof entry.streamOpen === "boolean") streamOpen = entry.streamOpen
  const stamped = { ...entry, at: new Date() }
  entries.unshift(stamped)
  if (entries.length > MAX_ENTRIES) entries.length = MAX_ENTRIES
  listeners.forEach((listener) => listener(stamped))
}

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.addEventListener("message", (event) => {
    const type = event.data?.type
    if (type === "instant_record.debug") record(event.data.entry)
    else if (type === "instant_record.debug_backlog") adopt(event.data)
    else if (type === "records_changed") record({ kind: "change", path: "records_changed" })
    else if (type === "sw_updated") record({ kind: "change", path: "new build activated" })
  })
}

// Asked for once per page load, never again: adopting replaces the list, and
// doing that on later visits would drop everything recorded since — including
// the change lines the page adds itself, which the worker's buffer never has.
let adopted = false

const adopt = ({ entries: backlog, streamOpen: open }) => {
  if (typeof open === "boolean") streamOpen = open
  entries.length = 0
  entries.push(...[...(backlog || [])].reverse())
  if (entries.length > MAX_ENTRIES) entries.length = MAX_ENTRIES
  listeners.forEach((listener) => listener(null))
}

const tellWorker = (settings, backlog = false) => {
  navigator.serviceWorker?.controller?.postMessage({
    type: "instant_record.simulate",
    settings,
    backlog,
  })
}

// Which parts of the flow map an entry lights up. The log says what happened;
// the map says where.
// Nothing that failed reached the far side, so only light what it touched —
// drawing the server for a request that never left the tab is the opposite of
// what the map is for.
const reachedTheServer = (entry) =>
  entry.status !== "offline" && entry.status !== "failed"

const flowsFor = (entry) => {
  switch (entry.kind) {
    case "local":
      // Served by the local runtime: view → wasm Rails → PGlite, with no
      // network anywhere on the path.
      return ["page", "local", "wasm", "db", "pglite"]
    case "sync":
      if (entry.method === "POST") {
        return reachedTheServer(entry)
          ? ["wasm", "up", "server", "postgres"]
          : ["wasm", "up"]
      }
      return reachedTheServer(entry) ? ["server", "down", "wasm"] : ["down"]
    case "stream":
      return reachedTheServer(entry)
        ? ["postgres", "server", "down", "wasm"]
        : ["down"]
    case "assets":
      // Still the local runtime serving them, just summarised.
      return ["page", "local", "wasm"]
    case "change":
      return ["wasm", "local", "page"]
    case "sync-pass":
      return ["wasm"]
    default:
      return []
  }
}

export default class extends Controller {
  static targets = ["log", "offline", "slow"]

  connect() {
    this.pulseTimers = new Map()
    this.render = (entry) => {
      // One new row is one insert, not a rebuild of the whole list: replacing
      // every row on every event is what made the log flicker and jump.
      if (entry) {
        this.append(entry)
        this.pulse(entry)
      } else {
        this.draw()
      }
      this.markStream()
    }
    listeners.add(this.render)

    this.offlineTarget.checked = ui.offline
    this.slowTarget.checked = ui.slow
    this.draw()
    this.markStream()

    // A reload restarts the page but not necessarily the worker, and a restarted
    // worker forgets. Re-state everything so the two always agree.
    this.push()
  }

  disconnect() {
    listeners.delete(this.render)
    this.pulseTimers.forEach((timer) => clearTimeout(timer))
    this.pulseTimers.clear()
  }

  // Both simulations act on the sync server only — the local runtime keeps
  // serving pages, which is the whole point of the demo.
  simulate() {
    ui.offline = this.offlineTarget.checked
    ui.slow = this.slowTarget.checked
    this.push()
    this.markBrokenWires()
  }

  clear() {
    entries.length = 0
    this.draw()
    // The worker holds the real buffer; without this the next page load adopts
    // it again and everything just cleared comes straight back.
    navigator.serviceWorker?.controller?.postMessage({ type: "instant_record.clear_log" })
  }

  push() {
    saveUi()
    const wantBacklog = !adopted
    adopted = true
    tellWorker(
      {
        report: true,
        offline: ui.offline,
        latencyMs: ui.slow ? SLOW_LATENCY_MS : 0,
      },
      wantBacklog,
    )
    this.markBrokenWires()
  }

  // A held connection is worth showing on its own: the wire is live even when
  // nothing is crossing it, which is the difference between SSE and polling.
  markStream() {
    const wire = this.element.querySelector('[data-flow="down"]')
    wire?.toggleAttribute("data-connected", streamOpen && !ui.offline)
  }

  // Offline doesn't stop the local runtime, so only the two wires crossing to
  // the server are drawn as broken.
  markBrokenWires() {
    this.element.querySelectorAll('[data-flow="up"], [data-flow="down"]').forEach((wire) => {
      wire.toggleAttribute("data-broken", ui.offline)
    })
  }

  pulse(entry) {
    for (const flow of flowsFor(entry)) {
      const part = this.element.querySelector(`[data-flow="${flow}"]`)
      if (!part) continue

      // Restart the animation rather than letting a second event be swallowed
      // by the first one's still-running keyframes.
      part.removeAttribute("data-active")
      void part.getBoundingClientRect()
      part.setAttribute("data-active", flow)

      clearTimeout(this.pulseTimers.get(flow))
      this.pulseTimers.set(
        flow,
        setTimeout(() => part.removeAttribute("data-active"), PULSE_MS),
      )
    }
  }

  append(entry) {
    const row = rowFor(entry)
    // Hold the reader's place. Newest is at the top, so an insert there pushes
    // whatever they are looking at down by exactly one row's height.
    const pinnedToTop = this.logTarget.scrollTop <= 2
    this.logTarget.prepend(row)
    if (!pinnedToTop) this.logTarget.scrollTop += row.offsetHeight

    while (this.logTarget.children.length > MAX_ENTRIES) {
      this.logTarget.lastElementChild.remove()
    }
  }

  // Only for a wholesale change: the worker's backlog, or Clear.
  draw() {
    this.logTarget.replaceChildren(...entries.map(rowFor))
  }
}

const rowFor = (entry) => {
  const row = document.createElement("li")
  row.dataset.kind = entry.kind
  row.dataset.status = statusClass(entry.status)
  row.innerHTML = `
    <span class="inspector-kind">${entry.kind}</span>
    <span class="inspector-path">${escapeHtml(label(entry))}</span>
    <span class="inspector-meta">${meta(entry)}</span>
  `
  return row
}

const label = (entry) => [entry.method, entry.path].filter(Boolean).join(" ")

const meta = (entry) =>
  [entry.status, entry.ms === undefined ? null : `${entry.ms}ms`]
    .filter((part) => part !== null && part !== undefined)
    .join(" · ")

const statusClass = (status) => {
  if (status === "offline" || status === "failed") return "bad"
  if (status === "busy") return "warn"
  return "ok"
}

const escapeHtml = (value) =>
  String(value).replace(
    /[&<>"']/g,
    (char) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char],
  )
