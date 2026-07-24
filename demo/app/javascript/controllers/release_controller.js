import { Controller } from "@hotwired/stimulus"

// Ship v2 runs real DDL plus a backfill inside the wasm VM, which is
// single-threaded: a second press while the first run is still in flight just
// queues behind it and reads as a dead button. Say what is happening instead.
export default class extends Controller {
  static targets = ["button"]

  ship() {
    this.buttonTarget.disabled = true
    this.buttonTarget.value = "Migrating…"
  }
}
