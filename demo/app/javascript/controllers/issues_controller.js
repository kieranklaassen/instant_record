import { Controller } from "@hotwired/stimulus"

// Todo without page reloads: submits go over fetch, and the list morphs in
// place — add, update, and (unlike the chat conversation) remove by data-id.
// Removal is safe here because this list is complete: the page renders every
// issue, so a row missing from a fresh render really is gone. The chat list
// is a window over history, where a missing row only means "not in the
// window", which is why its morph never removes.
//
// Scroll and focus survive because nothing outside a changed row is touched:
// the composer keeps its caret, and the reader keeps their place.
//
// Usage (see app/views/todo/issues/index.html.erb):
//   <div data-controller="issues"
//        data-instant-refresh
//        data-action="instant-record:records-changed@window->issues#sync">
//     <form data-action="submit->issues#submit">…</form>
//     <ul class="issues" data-issues-target="list">…</ul>
//     …<span data-issues-target="open|done|pending">…
//   </div>
export default class extends Controller {
  static targets = ["list", "open", "done", "pending"]

  connect() {
    this.busy = false
  }

  // Every form on the page — create, toggle, delete — posts here instead of
  // navigating. The write is already local in the browser runtime, so the
  // refetch right after paints it without a reload.
  async submit(event) {
    event.preventDefault()
    const form = event.target
    const input = form.querySelector("input[type='text']")
    const typed = input?.value
    const body = new FormData(form)
    if (form.dataset.method) body.set("_method", form.dataset.method)
    if (input) {
      input.value = ""
      input.focus()
    }

    try {
      // redirect: "manual" — create/update/destroy all redirect, and following
      // it would render a page we're about to diff away. The opaque redirect
      // (status 0) is the success path; a real error still has a status.
      const response = await fetch(form.action, { method: "POST", body, redirect: "manual" })
      if (response.type !== "opaqueredirect" && !response.ok) {
        throw new Error(`submit failed: ${response.status}`)
      }
      await this.sync()
    } catch {
      if (input) input.value = typed
      form.submit() // plain navigation fallback
    }
  }

  // instant-record:records-changed@window — same signal the chat page uses.
  async sync() {
    if (this.busy) return
    this.busy = true
    try {
      const doc = await fetchPage(window.location.pathname)
      if (!doc) return

      const fresh = doc.querySelector("ul.issues")
      if (fresh) morphRows(this.listTarget, fresh)

      // The red field's numbers live outside the list; swap their text only.
      for (const name of ["open", "done", "pending"]) {
        const target = `${name}Target`
        const freshValue = doc.querySelector(`[data-issues-target="${name}"]`)
        if (this[`has${name[0].toUpperCase()}${name.slice(1)}Target`] && freshValue) {
          this[target].textContent = freshValue.textContent
        }
      }
    } finally {
      this.busy = false
    }
  }
}

const fetchPage = async (url) => {
  try {
    const response = await fetch(url)
    if (!response.ok) return null
    return new DOMParser().parseFromString(await response.text(), "text/html")
  } catch {
    return null
  }
}

// One ascending pass, keyed by data-id: matched rows are replaced when their
// markup changed, new rows land after the last match, and rows absent from
// the fresh render are removed.
const morphRows = (current, fresh) => {
  const freshIds = new Set([...fresh.children].map((li) => li.dataset.id).filter(Boolean))
  for (const li of [...current.children]) {
    if (li.dataset.id && !freshIds.has(li.dataset.id)) li.remove()
  }

  const existing = new Map(
    [...current.children].filter((li) => li.dataset.id).map((li) => [li.dataset.id, li]),
  )

  let anchor = null
  for (const freshLi of fresh.children) {
    const id = freshLi.dataset.id
    if (!id) continue

    const node = existing.get(id)
    if (node) {
      if (node.outerHTML !== freshLi.outerHTML) {
        const updated = freshLi.cloneNode(true)
        node.replaceWith(updated)
        anchor = updated
      } else {
        anchor = node
      }
      continue
    }

    const added = freshLi.cloneNode(true)
    anchor ? anchor.after(added) : current.prepend(added)
    anchor = added
  }
}
