import { Controller } from "@hotwired/stimulus"

import * as localModel from "controllers/assistant_local_model"

// The Assistant's chats and turns are records, drawn by Rails views in both
// runtimes. This controller holds no conversation state. It does three things:
//
//   1. Sends a write and puts the answer on the page: the controller replies
//      with the live parts of the page, and they are folded in row by row.
//   2. Asks for those parts again when records change, or a chat is opened.
//   3. Asks the browser's own model, and saves its reply onto the turn.
//
// Which engine answers is the one thing kept here, since it is this browser's choice.

const ENGINE_KEY = "instant_record.relay.engine"
// What the browser's model is given as context: the last turns, each text clipped.
const HISTORY_TURNS = 6
const HISTORY_TEXT = 2000
const BOTTOM_SLACK_PX = 65
// How long to look for Rails' reply where no sync signal announces it.
const WATCH_MS = 1500
const WATCH_TRIES = 40

export default class extends Controller {
  static targets = ["scroll", "latest", "chat", "input", "send", "stop", "status", "engine"]

  connect() {
    this.local = "unavailable"
    this.requests = Promise.resolve()
    try { this.engine = localStorage.getItem(ENGINE_KEY) } catch { /* The default stands. */ }
    if (!["server", "local"].includes(this.engine)) this.engine = "auto"
    const wide = matchMedia("(min-width: 701px)").matches
    this.element.classList.toggle("history-open", wide)
    this.element.querySelector(".relay-menu").setAttribute("aria-expanded", String(wide))
    this.jumpToLatest()
    this.connection()
    this.checkLocalModel()
  }

  disconnect() {
    clearTimeout(this.watching)
    this.stop()
  }

  // --- The page, from records ------------------------------------------------

  // Ask the controller and fold its live parts into the page. One request at a
  // time: the compiled runtime renders on a single thread.
  load(href = location.href, options) {
    const url = new URL(href, location.origin)
    url.searchParams.set("fragment", "1")
    this.pending = (this.pending || 0) + 1
    const request = this.requests.then(async () => {
      const response = await fetch(url.pathname + url.search, options)
      if (!response.ok) throw new Error(`Assistant answered ${response.status}`)
      const fresh = document.createElement("template")
      fresh.innerHTML = await response.text()
      if (this.element.isConnected) this.fold(fresh.content)
    }).finally(() => { this.pending-- })
    this.requests = request.catch(() => {})
    return request
  }

  // Keep the reader's place: follow the newest turn from the bottom, and
  // otherwise hold the row they were looking at where it was.
  fold(fresh) {
    const scroll = this.scrollTarget
    const chat = this.turns.dataset.chat
    const pinned = scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight < BOTTOM_SLACK_PX
    const anchor = this.turns.querySelector(".relay-turn")
    const top = anchor?.getBoundingClientRect().top
    for (const part of fresh.querySelectorAll("[data-live]")) morph(document.getElementById(part.id), part)
    this.chatTarget.value = this.turns.dataset.chat
    if (pinned || chat !== this.turns.dataset.chat) scroll.scrollTop = scroll.scrollHeight
    else if (anchor?.isConnected) scroll.scrollTop += anchor.getBoundingClientRect().top - top
    this.scrolled()
  }

  get turns() {
    return document.getElementById("relay-turns")
  }

  // instant-record:records-changed, and Back or Forward.
  sync() {
    return this.load().catch(() => { /* The next signal asks again. */ })
  }

  // A chat in the list, or earlier messages: the same page at another address.
  navigate(event) {
    const link = event.target.closest("a[data-relay-link]")
    if (!link || event.metaKey || event.ctrlKey || event.shiftKey || event.button !== 0) return
    event.preventDefault()
    if (link.dataset.relayLink === "chat") this.open(link.getAttribute("href"))
    else history.replaceState(history.state, "", link.getAttribute("href"))
    this.sync()
  }

  open(href) {
    this.stop()
    history.pushState({}, "", href)
    if (matchMedia("(max-width: 700px)").matches && this.element.classList.contains("history-open")) this.toggleHistory()
  }

  newChat() {
    this.open(`${location.pathname}?chat=${crypto.randomUUID()}`)
    this.sync()
    this.inputTarget.focus()
  }

  // --- A question ------------------------------------------------------------

  async send(event) {
    event.preventDefault()
    const prompt = this.inputTarget.value.trim()
    const route = this.route
    if (!prompt || !route || this.active) return
    const form = this.inputTarget.form
    const body = new URLSearchParams(new FormData(form))
    body.set("turn[engine]", route)
    this.inputTarget.value = ""
    try {
      await this.load(form.getAttribute("action") + location.search, { method: "POST", body })
    } catch {
      this.inputTarget.value = prompt
      this.statusTarget.textContent = "Couldn’t save your question. It is back in the box."
      return
    }
    this.jumpToLatest()
    const turn = [...this.turns.querySelectorAll(".relay-turn[data-pending=true]")].at(-1)
    if (route === "local" && turn) this.answer(turn)
    else this.watch(WATCH_TRIES)
  }

  // Rails answers in a job. A compiled page hears of it through sync; a page
  // served by Rails has no such signal, so it looks again for a while.
  watch(tries) {
    clearTimeout(this.watching)
    if (!tries || !this.turns.querySelector(".relay-turn[data-pending=true][data-engine=server]")) return
    this.watching = setTimeout(async () => {
      await this.sync()
      this.watch(tries - 1)
    }, WATCH_MS)
  }

  // The browser's model answers a turn: its words appear as they come, and the
  // finished reply is saved onto the record like any other write.
  async answer(turn) {
    const control = new AbortController()
    const response = turn.querySelector(".relay-response")
    // By character, as Rails counts them, so no emoji is cut in half.
    const clip = text => Array.from(text.trim()).slice(0, HISTORY_TEXT).join("")
    const history = [...this.turns.querySelectorAll(".relay-turn[data-pending=false]")].slice(-HISTORY_TURNS)
      .map(earlier => [clip(earlier.querySelector(".relay-user").textContent), clip(earlier.querySelector(".relay-response").innerText)])
    let reply = ""
    this.active = control
    turn.dataset.busy = "true"
    this.working(true, "Thinking on this device…")
    try {
      await localModel.reply(turn.querySelector(".relay-user").textContent, history, { signal: control.signal, onText: text => {
        if (control.signal.aborted) return
        if (!reply) this.statusTarget.textContent = "Replying on this device…"
        reply = text
        const scroll = this.scrollTarget
        const pinned = scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight < BOTTOM_SLACK_PX
        response.textContent = text
        if (pinned) scroll.scrollTop = scroll.scrollHeight
      } })
    } catch {
      reply = (reply + "\n\n" + (control.signal.aborted ? "Reply stopped." : "The on-device model couldn’t answer.")).trim()
    }
    delete turn.dataset.busy
    this.active = null
    this.working(false)
    const body = new URLSearchParams({ _method: "patch", "turn[reply]": reply || "The on-device model gave no answer.", authenticity_token: this.inputTarget.form.elements.authenticity_token.value })
    await this.load(`${this.inputTarget.form.getAttribute("action")}/${encodeURIComponent(turn.id.slice("turn-".length))}${location.search}`, { method: "POST", body })
      .catch(() => { this.statusTarget.textContent = "Couldn’t save the reply." })
  }

  stop() {
    this.active?.abort()
  }

  working(busy, status) {
    this.inputTarget.readOnly = busy
    this.sendTarget.hidden = busy
    this.stopTarget.hidden = !busy
    if (busy) this.statusTarget.textContent = status
    else this.connection()
  }

  // --- Which engine answers --------------------------------------------------

  get offline() {
    return !navigator.onLine || document.querySelector("[data-inspector-target=offline]")?.checked
  }

  // Who is asked next: "server", "local", or null while the chosen model is not ready.
  get route() {
    const local = this.local === "available"
    if (this.engine === "local") return local ? "local" : null
    return this.engine === "auto" && this.offline && local ? "local" : "server"
  }

  connection() {
    const route = this.route
    this.sendTarget.disabled = !route
    this.engineTargets.forEach(input => {
      input.checked = input.value === this.engine
      if (input.value === "local") {
        input.disabled = this.local === "unavailable"
        input.parentElement.title = input.disabled ? "This browser has no built-in model. Chrome on a desktop offers Gemini Nano." : ""
      }
    })
    if (!this.active) this.statusTarget.textContent = this.hint(route)
  }

  hint(route) {
    if (this.downloaded != null) return `Downloading the on-device model… ${Math.round(this.downloaded * 100)}%`
    if (!route) return "The on-device model isn’t ready. Choose On-device again to download it."
    if (route === "local") return (this.offline ? "Offline. " : "") + "Replies come from the model in this browser, and are saved as records."
    if (this.offline) return "Offline. Your question is saved here, and Rails answers once it syncs."
    return "Replies come from Rails, which may ask a hosted model through RubyLLM."
  }

  async checkLocalModel() {
    this.local = await localModel.availability()
    if (!this.element.isConnected) return
    if (this.engine === "local" && this.local === "unavailable") this.engine = "auto"
    this.connection()
  }

  // A click, not a change: choosing On-device again retries a download that failed.
  async chooseEngine(event) {
    if (!event.target.matches("input[type=radio]")) return
    this.engine = event.target.value
    try { localStorage.setItem(ENGINE_KEY, this.engine) } catch { /* The choice lasts for this visit. */ }
    this.connection()
    if (this.engine !== "local" || this.local === "available" || this.downloaded != null) return
    this.downloaded = 0
    this.connection()
    try { await localModel.prepare(loaded => { this.downloaded = loaded; this.connection() }) }
    catch { /* The availability check below says where the download stands. */ }
    this.downloaded = null
    await this.checkLocalModel()
  }

  // --- Small things ----------------------------------------------------------

  toggleHistory() {
    const open = this.element.classList.toggle("history-open")
    this.element.querySelector(".relay-menu").setAttribute("aria-expanded", String(open))
  }

  // Near the top, earlier messages load by themselves.
  scrolled(event) {
    const scroll = this.scrollTarget
    if (event && scroll.scrollTop < 60 && !this.pending) this.turns.querySelector("#relay-older a")?.click()
    this.latestTarget.hidden = scroll.scrollHeight - scroll.clientHeight - scroll.scrollTop < BOTTOM_SLACK_PX
  }

  jumpToLatest() {
    this.scrollTarget.scrollTop = this.scrollTarget.scrollHeight
    this.scrolled()
  }

  key(event) {
    if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
      event.preventDefault()
      this.inputTarget.form.requestSubmit()
    }
  }

  suggest(event) {
    const button = event.target.closest("button")
    if (!button) return
    this.inputTarget.value = button.lastChild.textContent.trim()
    this.inputTarget.form.requestSubmit()
  }

  async copy(event) {
    const button = event.currentTarget
    try {
      await navigator.clipboard.writeText(button.parentElement.querySelector("code").textContent)
      button.textContent = "Copied"
    } catch {
      this.statusTarget.textContent = "Select the code and copy it manually."
    }
  }
}

// Make `current` read as `fresh` does, touching only what differs. Children are
// matched by id: a changed row is replaced, a new one lands after the row
// before it, and one that is gone is removed. A row marked busy is being
// written by the browser's model and is left alone.
const morph = (current, fresh) => {
  if (!current) return
  for (const { name, value } of fresh.attributes) current.setAttribute(name, value)
  if (!fresh.children.length) {
    if (current.textContent !== fresh.textContent) current.textContent = fresh.textContent
    return
  }
  const rows = new Map([...current.children].map(row => [row.id, row]))
  let before = null
  for (const row of [...fresh.children]) {
    const known = rows.get(row.id)
    rows.delete(row.id)
    if (known && (known.dataset.busy || known.outerHTML === row.outerHTML)) {
      before = known
      continue
    }
    if (known) known.replaceWith(row)
    else if (before) before.after(row)
    else current.prepend(row)
    before = row
  }
  rows.forEach(row => row.remove())
}
