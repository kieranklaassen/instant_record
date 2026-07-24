import { Controller } from "@hotwired/stimulus"

// Conversation behavior for the Swiss Slack demo: scroll up for older pages,
// fold live changes in, submit the composer without navigating.
//
// Three rules keep it from flickering. They are the whole design:
//
//   1. Nothing is inserted or removed above the message list. The history slot
//      is server-rendered (show.html.erb) and only ever changes state, so the
//      list never shifts.
//   2. Live updates only add and update rows. Never remove, never re-render the
//      list wholesale — a re-render is a visible blank frame, and a removal
//      pass that misjudges its range deletes messages outright.
//   3. Deletions arrive as a reload (the demo reset), not as a diff. That is
//      what lets rule 2 be unconditional.
//
// And one hard constraint: every fetch here is rendered by a single-threaded
// wasm VM, so a history load and a live merge never overlap — see whenIdle.
//
// Usage (see app/views/slack/channels/show.html.erb):
//   <div data-controller="conversation"
//        data-action="instant-record:records-changed@window->conversation#sync">
//     <div class="message-scroll" data-conversation-target="scroller"
//          data-action="scroll->conversation#scrolled">
//       <div class="history-sentinel" data-conversation-target="sentinel"></div>
//       <ol class="messages" data-conversation-target="list">…</ol>
//     </div>
//     <form data-action="conversation#send">…</form>
//   </div>

const PAGE_SIZE = 50
// How close to the top starts the next page. A plain scroll check, not an
// IntersectionObserver: scroll events re-fire, so a page that came back busy
// retries on the next one — no re-arming or re-observing to get right.
const LOAD_OLDER_AT_PX = 400
const BOTTOM_SLACK_PX = 60
// Local history resolves in ~30ms. Painting "Loading history…" for a frame and
// then replacing it is a flicker, so the label waits for a load slow enough to
// be worth announcing — one that actually went to the network.
const HISTORY_LABEL_DELAY_MS = 200

export default class extends Controller {
  static targets = ["scroller", "list", "sentinel", "threadList"]

  connect() {
    this.busy = false
    this.exhausted = this.listTarget.dataset.hasMore !== "true"
    this.scrollToBottom()
  }

  // --- Actions ---------------------------------------------------------------

  // scroll->conversation#scrolled
  scrolled() {
    if (this.scrollerTarget.scrollTop <= LOAD_OLDER_AT_PX) this.loadOlder()
  }

  // instant-record:records-changed@window — the layout forwards the service
  // worker's records_changed to pages with a data-instant-refresh root.
  // Skipped while the VM is busy; the next tick redoes it a few seconds later.
  async sync() {
    if (this.busy) return
    this.busy = true
    try {
      await this.merge()
    } finally {
      this.busy = false
    }
  }

  async send(event) {
    event.preventDefault()
    const form = event.target

    const input = form.querySelector("input[type='text']")
    const typed = input.value
    const body = new FormData(form)
    input.value = ""
    input.focus()

    try {
      // redirect: "manual" because create redirects, and following it would
      // make the browser re-render the whole page in the VM just to throw the
      // result away. The redirect comes back opaque (status 0), which is the
      // success path here; a real error still has a status to check.
      const response = await fetch(form.action, {
        method: "POST",
        body,
        redirect: "manual",
      })
      if (response.type !== "opaqueredirect" && !response.ok) {
        throw new Error(`send failed: ${response.status}`)
      }

      // The local write is already committed; show it now rather than waiting
      // for a tick. Unlike a tick this waits its turn — but only for a while:
      // barging in on a slow history load would risk the re-entrancy the guard
      // exists to prevent, and the tick the write just scheduled will bring the
      // message in anyway.
      if (await this.whenIdle()) {
        this.busy = true
        try {
          await this.merge({ stickToBottom: true })
        } finally {
          this.busy = false
        }
      }
    } catch {
      input.value = typed
      form.submit() // plain navigation fallback
    }
  }

  // --- Live updates ----------------------------------------------------------

  // Fold the newest window into the page: add rows we don't have, refresh ones
  // whose markup changed (a sync badge flipping), leave everything else alone.
  //
  // Fetched without a floor, so the response is just the newest page — cheap,
  // bounded, and it never has to reason about how far back the reader scrolled.
  // Scrollback the reader loaded stays put because nothing is ever removed.
  async merge({ stickToBottom = false } = {}) {
    const stick = stickToBottom || nearBottom(this.scrollerTarget)

    // Offline or a bad response: keep what's on screen and let the next tick
    // retry.
    const fresh = await fetchList(this.listTarget.dataset.fragmentUrl, "ol.messages")
    if (!fresh) return

    mergeRows(this.listTarget, fresh)
    if (stick) this.scrollToBottom()

    // The open thread panel refreshes on the same signal with the same morph —
    // replies are rows with data-id like everything else. Its own fragment URL
    // carries the ?thread param, so the server renders just the replies list.
    if (this.hasThreadListTarget) {
      const replies = await fetchList(
        this.threadListTarget.dataset.threadFragmentUrl,
        "ol.thread-replies",
      )
      if (replies) mergeRows(this.threadListTarget, replies)
    }
  }

  // --- History ---------------------------------------------------------------

  async loadOlder() {
    if (this.busy || this.exhausted) return

    const before = {
      created_at: this.listTarget.dataset.oldestCreatedAt,
      id: this.listTarget.dataset.oldestId,
    }
    // A fresh client can render before the cursor attributes are filled; firing
    // with blank cursors would error. The next scroll retries.
    if (!before.created_at || !before.id) return

    this.busy = true
    const announce = setTimeout(
      () => this.setSlot("loading", "Loading history…"),
      HISTORY_LABEL_DELAY_MS,
    )

    try {
      // In the browser, pull the page into the local database first; the VM
      // only reaches the network for pages it doesn't already hold. On the
      // server the rendered page answers for itself.
      let hasMore = null
      if (swControlled()) {
        const reply = await fetchHistoryViaWorker({
          type: "Message",
          partition: this.listTarget.dataset.channelId,
          before,
          limit: PAGE_SIZE,
        })
        // busy means a sync pass held the VM — transient, so leave it be and
        // let the next scroll retry. Only a real failure says offline.
        if (reply.busy) return this.setSlot("idle", "")
        if (!reply.ok) return this.offline(reply.error)
        hasMore = reply.has_more
      }

      const page = await this.fetchOlderPage(before)
      if (!page) return this.offline("history page fetch failed")

      this.prepend(page)
      if (hasMore === null) hasMore = page.dataset.hasMore === "true"
      this.exhausted = !hasMore
      if (this.exhausted) this.markBeginning()
      else this.setSlot("idle", "")
    } finally {
      clearTimeout(announce)
      this.busy = false
    }
  }

  // The wasm VM is single-threaded and must not be entered twice at once: a
  // Rack render arriving while a history fetch is suspended is the asyncify
  // re-entrancy that takes the whole runtime down. Returns whether the VM went
  // idle, so a caller that can't wait forever declines rather than barges in.
  async whenIdle(attempts = 40) {
    for (let i = 0; i < attempts && this.busy; i++) {
      await new Promise((resolve) => setTimeout(resolve, 50))
    }
    return !this.busy
  }

  fetchOlderPage(before) {
    const url = new URL(this.listTarget.dataset.fragmentUrl, window.location.origin)
    url.searchParams.set("floor_created_at", before.created_at)
    url.searchParams.set("floor_id", before.id)
    url.searchParams.set("deepen", "1")

    return fetchList(url, "ol.messages")
  }

  // Prepend the rows we don't have, holding the viewport on whatever the reader
  // was looking at. Anchoring is manual because overflow-anchor is off (Safari
  // has none, and leaving it on double-compensates).
  prepend(page) {
    const container = this.scrollerTarget
    const known = new Set([...this.listTarget.children].map((li) => li.dataset.id))
    const older = [...page.children].filter(
      (li) => li.dataset.id && !known.has(li.dataset.id),
    )

    if (older.length) {
      const heightBefore = container.scrollHeight
      this.listTarget.prepend(...older.map((li) => li.cloneNode(true)))
      container.scrollTop += container.scrollHeight - heightBefore
    }

    // Advance the cursor even when the page held nothing new, or the next scroll
    // asks for the same page again and scrollback stalls there.
    this.listTarget.dataset.oldestCreatedAt = page.dataset.oldestCreatedAt
    this.listTarget.dataset.oldestId = page.dataset.oldestId
  }

  // --- The history slot ------------------------------------------------------

  setSlot(state, text) {
    if (!this.hasSentinelTarget) return
    this.sentinelTarget.dataset.state = state
    this.sentinelTarget.textContent = text
  }

  // Converts the slot in place — it keeps its box, so the list never moves. No
  // slot means the server already rendered the marker into the list itself.
  markBeginning() {
    this.setSlot("beginning", "")
    if (!this.hasSentinelTarget) return
    this.sentinelTarget.innerHTML = `<span class="micro-label">Beginning of history</span>`
  }

  offline(reason) {
    console.warn("[slack] history unavailable:", reason)
    this.setSlot("offline", "History is unavailable offline — reconnect to load more.")
  }

  scrollToBottom() {
    this.scrollerTarget.scrollTop = this.scrollerTarget.scrollHeight
  }
}

// --- Stateless helpers -------------------------------------------------------

const swControlled = () =>
  "serviceWorker" in navigator && !!navigator.serviceWorker.controller

// All callers want the same thing from a render: one list out of the fragment,
// or null if the page couldn't be reached. A thrown fetch and a non-ok
// response mean the same thing to them, so they're answered the same way.
const fetchList = async (url, selector) => {
  try {
    const response = await fetch(url)
    if (!response.ok) return null
    const doc = new DOMParser().parseFromString(await response.text(), "text/html")
    return doc.querySelector(selector)
  } catch {
    return null
  }
}

const fetchHistoryViaWorker = (request) =>
  new Promise((resolve) => {
    const channel = new MessageChannel()
    // An unresponsive worker recovers on a later attempt; busy keeps the slot
    // idle instead of latching the offline notice.
    const timer = setTimeout(
      () => resolve({ ok: false, busy: true, error: "history request timed out" }),
      15000,
    )
    channel.port1.onmessage = (event) => {
      clearTimeout(timer)
      resolve(event.data || { ok: false, error: "empty reply" })
    }
    navigator.serviceWorker.controller.postMessage(
      { type: "instant_record.fetch_history", request },
      [channel.port2],
    )
  })

// Add and update by data-id; never remove. Both lists are ascending, so one
// pass keeps order: matched rows advance the anchor, new rows land after it.
// Rows without a data-id are markers and are left alone.
const mergeRows = (current, fresh) => {
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

    // A row we don't have. It belongs after the last row we matched; with no
    // match yet it belongs at the end, since this page is the newest slice.
    const added = freshLi.cloneNode(true)
    anchor ? anchor.after(added) : current.append(added)
    anchor = added
  }
}

const nearBottom = (container) =>
  container.scrollHeight - container.scrollTop - container.clientHeight <
  BOTTOM_SLACK_PX
