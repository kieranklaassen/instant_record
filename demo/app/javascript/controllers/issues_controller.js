import { Controller } from "@hotwired/stimulus"

// Todo without page reloads: submits go over fetch with ?fragment=1, so the
// controller writes and returns the updated <ul> partial in a single round trip
// with no layout render or second GET. The list morphs in place — add, update,
// and remove by data-id — so scroll position and composer focus survive every
// change.
export default class extends Controller {
  static targets = ["list", "open", "done", "pending"]

  connect() {
    this.busy = false
  }

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
      const url = withFragment(form.action)
      const response = await fetch(url, { method: "POST", body })
      if (!response.ok) throw new Error(`submit failed: ${response.status}`)

      const fresh = parseList(await response.text())
      if (fresh) this.applyList(fresh)
      else await this.sync()
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
      const response = await fetch(withFragment(window.location.pathname))
      if (!response.ok) return
      const fresh = parseList(await response.text())
      if (fresh) this.applyList(fresh)
    } catch {
      // keep current DOM until next signal
    } finally {
      this.busy = false
    }
  }

  applyList(fresh) {
    morphRows(this.listTarget, fresh)
    if (this.hasOpenTarget && fresh.dataset.open !== undefined) {
      this.openTarget.textContent = fresh.dataset.open
    }
    if (this.hasDoneTarget && fresh.dataset.done !== undefined) {
      this.doneTarget.textContent = fresh.dataset.done
    }
    if (this.hasPendingTarget && fresh.dataset.pending !== undefined) {
      this.pendingTarget.textContent = fresh.dataset.pending
    }
  }
}

const withFragment = (href) => {
  const url = new URL(href, window.location.origin)
  url.searchParams.set("fragment", "1")
  return url.pathname + url.search
}

const parseList = (html) => {
  const template = document.createElement("template")
  template.innerHTML = html.trim()
  return template.content.querySelector("ul.issues")
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
