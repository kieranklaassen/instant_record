import { Controller } from "@hotwired/stimulus"

// The REPL on /console. Everything it displays was rendered by Rails: the
// controller evaluates the line and returns the transcript row as HTML, so
// inspecting a value, timing it, or naming an error class never gets
// reimplemented here. This file posts a form and appends the answer.
//
// Usage (see views/console/sessions/index.html.erb):
//   <div data-controller="console">
//     <button data-action="console#run" data-console-code-param="Issue.count">
//     <ol data-console-target="transcript">
//     <form data-console-target="form" data-action="console#submit">
//       <textarea data-console-target="input"
//                 data-action="keydown.meta+enter->console#submit">
export default class extends Controller {
  static targets = ["input", "transcript", "form"]

  connect() {
    this.busy = false
  }

  // Results are evidence of something that just happened. Restoring them from
  // Turbo's snapshot on a back-navigation would show answers nobody asked for,
  // so the transcript does not survive leaving the page.
  disconnect() {
    this.transcriptTarget.replaceChildren()
  }

  // console#run — a preloaded snippet. Fills the prompt as well as running it, so
  // what ran is visible and editable rather than hidden behind a button.
  run({ params: { code } }) {
    this.inputTarget.value = code
    this.evaluate()
  }

  submit(event) {
    event.preventDefault()
    this.evaluate()
  }

  // One line at a time: the wasm VM is single-threaded, so a second request while
  // the first is still rendering would just queue behind it.
  async evaluate() {
    if (this.busy || !this.inputTarget.value.trim()) return

    this.busy = true
    try {
      const response = await fetch(this.formTarget.action, {
        method: "POST",
        body: new FormData(this.formTarget),
      })
      if (!response.ok) throw new Error(`eval failed: ${response.status}`)
      this.transcriptTarget.insertAdjacentHTML("beforeend", await response.text())
    } catch (error) {
      console.warn("[console] eval unavailable:", error)
      this.note("The runtime didn't answer. It may be mid-sync — try the line again.")
    } finally {
      this.busy = false
      this.transcriptTarget.lastElementChild?.scrollIntoView({ block: "nearest" })
    }
  }

  // Text, not markup: the transcript's HTML has exactly one author, and it is
  // _result.html.erb.
  note(text) {
    const entry = document.createElement("li")
    entry.className = "console-entry failed"
    entry.textContent = text
    this.transcriptTarget.append(entry)
  }
}
