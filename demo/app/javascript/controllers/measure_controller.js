import { Controller } from "@hotwired/stimulus"

// Fills the receipts page with figures measured in this browser. Two sources:
// the service worker's boot ledger (bytes and phase timings it measured while
// booting), and a probe this controller runs now — the same Rails action fetched
// twice at the same moment, once locally and once over the network.
//
// The worker's ledger only lives for as long as the worker does, and a cold boot
// happens on a page that is long gone by the time anyone reads this one, so the
// splash and this controller both keep the last ledger of each kind in
// localStorage. Cold and warm are told apart by what was measured — whether the
// bundle crossed the network — never by which visit it was.
const STORE = "instant_record.boot."
const SOURCES = ["network", "cache"]

const fmtMs = (value) => {
  if (value >= 1000) return `${(value / 1000).toFixed(1)} s`
  if (value >= 10) return `${Math.round(value)} ms`
  return `${value.toFixed(1)} ms`
}

// MB as 10^6 bytes, said out loud on the page. The exact count travels with it,
// because the point of measuring is that the round number is not the number.
const fmtMb = (bytes) => `${(bytes / 1e6).toFixed(1)} MB`
const fmtBytes = (bytes) => `${bytes.toLocaleString()} bytes`

export default class extends Controller {
  static targets = ["cell", "status", "remeasure", "wipe"]
  static values = { localUrl: String, serverUrl: String }

  connect() {
    // Set before any await: a Turbo navigation can disconnect this controller
    // while a probe is still in flight, and a resolved fetch must not write to
    // a page that is gone.
    this.live = true
    this.listener = (event) => this.receive(event.data || {})
    navigator.serviceWorker?.addEventListener("message", this.listener)

    this.showRuntime()
    SOURCES.forEach((source) => this.showBoot(source, this.stored(source)))
    this.showBootNote()
    this.showBundle(SOURCES.map((source) => this.stored(source)))

    // The worker that booted this tab may have done so before this page
    // existed; its ledger is still there to ask for.
    navigator.serviceWorker?.controller?.postMessage({
      type: "instant_record.boot_ledger",
    })

    this.probe()
  }

  disconnect() {
    this.live = false
    navigator.serviceWorker?.removeEventListener("message", this.listener)
  }

  receive(data) {
    if (data.type !== "instant_record.boot_done" || data.ledger.totalMs === null) return

    const source = this.bundleSource(data.ledger)
    if (source === "unknown") return

    localStorage.setItem(STORE + source, JSON.stringify(data.ledger))
    this.showBoot(source, data.ledger)
    this.showBundle([data.ledger])
  }

  // --- The probe -------------------------------------------------------------

  remeasure() {
    this.probe()
  }

  async probe() {
    this.remeasureTarget.disabled = true
    this.status("Measuring…")

    // Both at once, on purpose: whatever the network is doing at this instant,
    // it is doing to both requests.
    const [local, server] = await Promise.all([
      this.time(this.localUrlValue),
      this.time(this.serverUrlValue),
    ])

    if (!this.live) return

    this.showProbe("local", local)
    this.showProbe("server", server)
    this.showRatio(local, server)

    this.remeasureTarget.disabled = false
    this.status("")
  }

  // The ratio is the only derived figure on the page, and it is reported in
  // whichever direction the measurement went — including the visits where the
  // server wins, which happens on a fast local network against a runtime that
  // has just booted.
  showRatio(local, server) {
    if (!local.body || !server.body) {
      this.figure("trip.ratio", "—")
      this.figure(
        "probe.note",
        "The server did not answer — offline, or the sync inspector's offline switch is on. The local figures were unaffected, which is rather the point.",
      )
      return
    }

    const rows = local.body.rows
    const ratio = server.ms / local.ms

    if (!this.localRuntime) {
      this.figure("trip.ratio", "not comparable")
      this.figure(
        "probe.note",
        `One runtime, asked twice: the server served this page, so both requests went to it and neither avoided the network. The table holds ${rows} issues. Open this page from the local runtime to get the comparison.`,
      )
      return
    }

    this.figure("trip.ratio", `${ratio.toFixed(1)}×`, "accent")
    this.figure(
      "probe.note",
      ratio >= 1
        ? `The same request cost ${ratio.toFixed(1)}× as much once the network was in the path. Both runtimes queried their own copy; the local table holds ${rows} issues.`
        : `The server answered faster than the local runtime this time — measured, not flattering. A just-booted VM loading a controller for the first time can lose to a warm server on a local network; re-measure to see it settle. The local table holds ${rows} issues.`,
    )
  }

  async time(url) {
    const startedAt = performance.now()

    try {
      const response = await fetch(url, {
        headers: { accept: "application/json" },
        cache: "no-store",
      })
      const body = await response.json()

      return { ms: performance.now() - startedAt, body }
    } catch (error) {
      return {}
    }
  }

  showProbe(side, result) {
    if (!result.body) {
      for (const row of ["trip", "query", "write"]) this.figure(`${side}.${row}`, "unreachable")
      return
    }

    this.figure(`${side}.trip`, fmtMs(result.ms), side === "local" ? "accent" : null)
    this.figure(`${side}.query`, fmtMs(result.body.query_ms))
    this.figure(`${side}.write`, fmtMs(result.body.write_ms))
  }

  // --- Boot ledgers ----------------------------------------------------------

  showBoot(source, ledger) {
    if (!ledger) return

    ledger.entries.forEach((entry) => this.figure(`${source}.${entry.phase}`, fmtMs(entry.ms)))

    // The total is wall clock from the worker, plus the first render the splash
    // timed after it — not a sum of the rows, which would miss the gaps.
    const render = ledger.entries.find((entry) => entry.phase === "render")
    this.figure(`${source}.total`, fmtMs(ledger.totalMs + (render?.ms ?? 0)))
    this.figure(`${source}.at`, new Date(ledger.at).toLocaleString())
    this.showBootNote()
  }

  showBootNote() {
    const missing = SOURCES.filter((source) => !this.stored(source))

    this.figure(
      "boot.note",
      missing.length === 0
        ? "Both boots were recorded in this browser."
        : missing.includes("network")
          ? "No boot that pulled the bundle over the network has been recorded in this browser yet — the wipe below records one."
          : "No boot from a cached bundle recorded yet; one happens on its own when the worker restarts after an idle stop.",
    )
  }

  // The most recent ledger wins the bundle rows — it measured the bundle this
  // browser is actually running.
  showBundle(ledgers) {
    const newest = ledgers.filter(Boolean).sort((a, b) => b.at - a.at)[0]
    const entry = newest?.entries.find((each) => each.phase === "bundle")
    if (!entry) return

    this.figure("bundle.bytes", fmtMb(entry.bytes), null, fmtBytes(entry.bytes))
    this.figure(
      "bundle.wire",
      entry.wireBytes ? fmtMb(entry.wireBytes) : "not reported by this browser",
      null,
      entry.wireBytes
        ? entry.wireBytes < entry.bytes
          ? fmtBytes(entry.wireBytes)
          : `${fmtBytes(entry.wireBytes)}, uncompressed by this server`
        : null,
    )
    this.figure(
      "bundle.source",
      entry.cached === null || entry.cached === undefined
        ? "not reported by this browser"
        : entry.cached
          ? "this browser's cache"
          : "the network",
    )
  }

  stored(source) {
    const raw = localStorage.getItem(STORE + source)
    return raw ? JSON.parse(raw) : null
  }

  bundleSource(ledger) {
    const bundle = ledger.entries.find((entry) => entry.phase === "bundle")
    if (!bundle || bundle.cached === null || bundle.cached === undefined) return "unknown"

    return bundle.cached ? "cache" : "network"
  }

  // --- A repeatable cold boot ------------------------------------------------

  async wipe() {
    const worker = navigator.serviceWorker?.controller

    if (!worker) {
      this.status("This page is being served by the server, so there is no local runtime here to wipe.")
      return
    }

    if (
      !confirm(
        "Delete this app's local database, caches and service worker, then reload into a first-visit boot?\n\nAnything written locally and not yet synced is lost.",
      )
    ) {
      return
    }

    this.wipeTarget.disabled = true
    this.status("Closing the local database and unregistering the worker…")

    // The worker lets go first — the stream it holds open, the database, the
    // caches, its own registration.
    await new Promise((resolve) => {
      const channel = new MessageChannel()
      channel.port1.onmessage = resolve
      worker.postMessage({ type: "instant_record.wipe_local_data" }, [channel.port2])
    })

    // Then the splash: it deletes the database (only a page no worker controls
    // can) and itemises the first-visit boot that follows.
    window.location.href = "/?instant_record_cold_boot=1"
  }

  // --- Writing figures -------------------------------------------------------

  figure(key, text, className = null, sub = null) {
    this.cellTargets
      .filter((cell) => cell.dataset.figure === key)
      .forEach((cell) => {
        cell.textContent = text
        cell.classList.toggle("accent", className === "accent")

        if (!sub) return

        const exact = document.createElement("span")
        exact.className = "exact"
        exact.textContent = sub
        cell.appendChild(exact)
      })
  }

  status(text) {
    this.statusTarget.textContent = text
  }

  // A worker controlling this tab is what makes the page local: it is the thing
  // that served this HTML out of the wasm bundle.
  get localRuntime() {
    return Boolean(navigator.serviceWorker?.controller)
  }

  showRuntime() {
    this.figure(
      "runtime",
      this.localRuntime
        ? "This page was rendered by Rails on ruby.wasm, in this tab."
        : "This page was rendered by the server: no local runtime is controlling this tab, so the two columns below are the same round trip and there is nothing local to compare.",
    )

    if (!this.localRuntime) this.wipeTarget.disabled = true
  }
}
