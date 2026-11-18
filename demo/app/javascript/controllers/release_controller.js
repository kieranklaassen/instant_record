import { Controller } from "@hotwired/stimulus"

// Ship v2 runs real DDL plus a backfill inside the wasm VM, which is
// single-threaded: a second press while the first run is still in flight just
// queues behind it and reads as a dead button. Say what is happening instead.
export default class extends Controller {
  static targets = ["button"]

  // Refresh server-driven values without replacing the form or its focused field.
  async refresh() {
    const request = Symbol()
    this.currentRefresh = request
    const response = await fetch(location.pathname)
    if (!response.ok) return
    const template = document.createElement("template")
    template.innerHTML = await response.text()
    if (!this.element.isConnected || this.currentRefresh !== request) return
    for (const selector of ["dl.facts", "table.notes"]) {
      const next = template.content.querySelector(selector)
      if (next) this.element.querySelector(selector)?.replaceWith(next)
    }
  }

  ship() {
    this.buttonTarget.disabled = true
    this.buttonTarget.value = "Migrating…"
  }
}
