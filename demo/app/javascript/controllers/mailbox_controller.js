import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["mail"]

  connect() {
    this.refresh = async () => {
      this.request?.abort()
      const request = this.request = new AbortController()
      const url = new URL(location.href)
      url.searchParams.set("fragment", "1")
      try {
        const response = await fetch(url, { signal: request.signal })
        const html = await response.text()
        if (response.ok && !request.signal.aborted) this.mailTarget.innerHTML = html
      } catch (error) {
        if (!request.signal.aborted) console.warn("Mailbox refresh failed", error)
      }
    }
    window.addEventListener("instant-record:records-changed", this.refresh)
  }

  disconnect() {
    this.request?.abort()
    window.removeEventListener("instant-record:records-changed", this.refresh)
  }
}
