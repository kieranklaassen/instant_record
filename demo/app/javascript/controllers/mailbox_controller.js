import { fetchHistoryViaWorker } from "controllers/history_page"
import { Controller } from "@hotwired/stimulus"

const PAGE_SIZE = 50
const MAX_ROWS = PAGE_SIZE * 3

export default class extends Controller {
  static targets = ["mail", "status", "older"]

  connect() {
    this.hasNewer = false
    this.localizeTimes(this.mailTarget)
    this.changed = () => this.refresh()
    window.addEventListener("instant-record:records-changed", this.changed)
  }

  olderTargetConnected(sentinel) {
    this.observer?.disconnect()
    this.observer = new IntersectionObserver(entries => {
      if (entries.some(entry => entry.isIntersecting) && sentinel.isConnected) this.older()
    }, { root: sentinel.closest(".mail-list"), rootMargin: "0px 0px 240px" })
    this.observer.observe(sentinel)
  }

  olderTargetDisconnected() { this.observer?.disconnect() }

  disconnect() {
    this.request?.abort()
    window.removeEventListener("instant-record:records-changed", this.changed)
  }

  get list() { return this.mailTarget.querySelector(".mail-list") }

  scroll() {
    const list = this.list
    if (list.scrollTop < 240 && this.hasNewer) this.page(true)
    else if (list.scrollHeight - list.scrollTop - list.clientHeight < 240) this.older()
  }

  older() {
    if (this.list.querySelector(".mail-older")) this.page(false)
  }

  async fragment(before, at, limit = PAGE_SIZE, signal, after) {
    const url = new URL(location.href)
    url.searchParams.set("before", before)
    url.searchParams.set("at", at)
    if (after) url.searchParams.set("after", after)
    url.searchParams.set("limit", limit)
    url.searchParams.set("fragment", "1")
    const thread = this.mailTarget.querySelector(".mail-reader").dataset.thread
    if (thread) url.searchParams.set("thread", thread)
    const response = await fetch(url, { signal })
    if (!response.ok) throw new Error("Mailbox request failed")
    const template = document.createElement("template")
    template.innerHTML = await response.text()
    this.localizeTimes(template.content)
    return template.content
  }

  // Keep the first visible row at its screen coordinate as rows enter or leave the window.
  anchor(list) {
    const top = list.getBoundingClientRect().top
    const row = [...list.querySelectorAll(".mail-row")].find(el => el.getBoundingClientRect().bottom > top)
    return row && { id: row.dataset.id, y: row.getBoundingClientRect().top }
  }

  restore(list, anchor) {
    if (!anchor) return
    const row = list.querySelector(`[data-id="${CSS.escape(anchor.id)}"].mail-row`)
    if (row) list.scrollTop += row.getBoundingClientRect().top - anchor.y
  }

  async page(newer) {
    if (this.loading || this.request) return
    this.loading = true
    const list = this.list
    const button = list.querySelector(".mail-older")
    const cursor = newer ? list.querySelector(".mail-row").dataset : button.dataset
    try {
      let more = true
      if (!newer && window.__spinel?.worker) {
        const result = await fetchHistoryViaWorker({ type: "MailEntry", before: { created_at: cursor.at, id: cursor.id }, limit: PAGE_SIZE })
        if (!result.ok) throw new Error("History unavailable")
        more = result.has_more !== false
      }
      if (!list.isConnected) return
      const fragment = await this.fragment(cursor.id, cursor.at, PAGE_SIZE, undefined, newer && cursor.id)
      if (!list.isConnected) return
      const anchor = this.anchor(list)
      const existing = [...list.querySelectorAll(".mail-row")]
      const ids = new Set(existing.map(row => row.dataset.id))
      const rows = [...fragment.querySelectorAll(".mail-row")].filter(row => !ids.has(row.dataset.id))
      if (newer) {
        existing[0].before(...rows)
        const start = fragment.querySelector(".mail-list").dataset
        Object.assign(list.dataset, { before: start.before, at: start.at })
        this.hasNewer = Boolean(start.before)
      } else {
        button.before(...rows)
      }
      button?.remove()
      const combined = [...list.querySelectorAll(".mail-row")]
      if (!newer && combined.length > MAX_ROWS) {
        const removed = combined.splice(0, combined.length - MAX_ROWS)
        this.hasNewer = true
        Object.assign(list.dataset, { before: removed.at(-1).dataset.id, at: removed.at(-1).dataset.at })
        removed.forEach(row => row.remove())
      } else if (newer) {
        combined.splice(MAX_ROWS).forEach(row => row.remove())
      }
      if (newer || (more && rows.length && fragment.querySelector(".mail-older"))) {
        // An invisible sentinel, not a button: older mail arrives as the
        // reader scrolls, with nothing to press.
        const next = button || document.createElement("div")
        next.className = "mail-older"
        next.setAttribute("aria-hidden", "true")
        next.dataset.mailboxTarget = "older"
        Object.assign(next.dataset, { id: combined.at(-1).dataset.id, at: combined.at(-1).dataset.at })
        list.append(next)
      }
      this.restore(list, anchor)
    } catch {
      if (list.isConnected) this.statusTarget.textContent = "Older mail is unavailable. Scroll again to retry."
    } finally {
      this.loading = false
      if (this.refreshPending && list.isConnected) this.refresh()
    }
  }

  async generate(event) {
    const button = event.currentTarget
    button.disabled = true
    this.statusTarget.textContent = "Receiving…"
    try {
      const response = await fetch(button.dataset.url, { method: "POST" })
      if (!response.ok) throw new Error()
      if (!this.element.isConnected) return
      this.statusTarget.textContent = "Email received"
      await this.refresh()
    } catch {
      if (this.element.isConnected) this.statusTarget.textContent = "Couldn’t receive mail. Check your connection."
    } finally {
      button.disabled = false
    }
  }

  localizeTimes(container) {
    const today = new Date().toDateString()
    for (const element of container.querySelectorAll("time[datetime]")) {
      const date = new Date(element.dateTime)
      if (Number.isNaN(date.valueOf())) continue
      element.textContent = date.toDateString() === today
        ? date.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })
        : date.toLocaleDateString([], { month: "short", day: "numeric" })
      element.title = date.toLocaleString()
    }
  }

  async refresh() {
    if (this.loading) {
      this.refreshPending = true
      return
    }
    this.refreshPending = false
    this.request?.abort()
    const request = this.request = new AbortController()
    const list = this.list
    const reader = this.mailTarget.querySelector(".mail-reader")
    try {
      const count = list.querySelectorAll(".mail-row").length
      const fragment = await this.fragment(list.dataset.before, list.dataset.at, Math.max(PAGE_SIZE, count), request.signal)
      if (request.signal.aborted || !list.isConnected) return
      const top = list.scrollTop
      const anchor = top > 0 && this.anchor(list)
      const refreshed = fragment.querySelector(".mail-list")
      list.replaceChildren(...refreshed.childNodes)
      list.scrollTop = top
      this.restore(list, anchor)
      const next = fragment.querySelector(".mail-reader")
      if (reader.dataset.thread !== next.dataset.thread || reader.dataset.compose !== next.dataset.compose) {
        reader.replaceWith(next)
      } else if (reader.dataset.thread) {
        reader.querySelector(".mail-replies").replaceWith(next.querySelector(".mail-replies"))
      }
    } catch (error) {
      if (!request.signal.aborted) console.warn("Mailbox refresh failed", error)
    } finally {
      if (this.request === request) this.request = null
    }
  }
}
