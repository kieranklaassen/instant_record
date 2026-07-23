import { Controller } from "@hotwired/stimulus"

// Submits the demo reset, then reloads. A reset is the one thing that deletes
// records, and live updates deliberately never remove rows (see
// conversation_controller.js) — so the reload is how deletions become visible.
export default class extends Controller {
  submit(event) {
    event.preventDefault()
    fetch(this.element.action, { method: "POST" })
      .then((response) => {
        if (!response.ok) throw new Error(`reset failed: ${response.status}`)
        window.location.reload()
      })
      .catch(() => {
        alert(
          "Reset needs the sync server — you appear to be offline. Try again once you're connected.",
        )
      })
  }
}
