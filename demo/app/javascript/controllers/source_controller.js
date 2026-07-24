import { Controller } from "@hotwired/stimulus"

// Fills the source drawer the first time it is opened. The drawer is a <details>
// element, so opening and closing is the browser's job; this controller only
// fetches.
//
// Fetched rather than server-rendered inline for two reasons. Rendering several
// files into every page would spend wasm VM time on a drawer most visitors leave
// shut — and because it is a request, it shows up in the sync inspector as a
// local render, which is the claim the drawer is making anyway.
//
// Usage (see layouts/application.html.erb):
//   <details data-controller="source"
//            data-source-url-value="/source?page=todo/issues&view=index"
//            data-action="toggle->source#load">
//     <summary>…</summary>
//     <div data-source-target="body"></div>
//   </details>
export default class extends Controller {
  static targets = ["body"]
  static values = { url: String }

  connect() {
    this.loaded = false
  }

  // Turbo snapshots the page on the way out. Fetched source left in that
  // snapshot would come back on a restore already open and already stale, so the
  // drawer leaves the way it arrived: shut and empty.
  disconnect() {
    this.element.open = false
    this.bodyTarget.replaceChildren()
    this.loaded = false
  }

  // toggle->source#load
  async load() {
    if (!this.element.open || this.loaded) return

    this.bodyTarget.textContent = "Reading the bundle…"
    try {
      const response = await fetch(this.urlValue)
      if (!response.ok) throw new Error(`source failed: ${response.status}`)
      this.bodyTarget.innerHTML = await response.text()
      this.loaded = true
    } catch (error) {
      console.warn("[source] unavailable:", error)
      this.bodyTarget.textContent =
        "This runtime didn't answer — it may be mid-sync. Close the drawer and open it again."
    }
  }
}
