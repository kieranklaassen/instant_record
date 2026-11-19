import { Controller } from "@hotwired/stimulus"

import { exampleChats } from "controllers/assistant_examples"
import * as localModel from "controllers/assistant_local_model"

const PREFIX = "instant_record.relay.turn."
const ENGINE_KEY = "instant_record.relay.engine"
// What the server accepts as context: the last turns, each text clipped.
const HISTORY_TURNS = 6
const HISTORY_TEXT = 2000
// Chrome serves Gemini Nano through the Prompt API; another browser may serve another model.
const LOCAL_NAME = "On-device model"
const node = (tag, className, text) => {
  const element = document.createElement(tag)
  element.className = className
  element.textContent = text
  return element
}

export default class extends Controller {
  static targets = ["older", "latest", "history", "title", "welcome", "transcript", "scroll", "input", "send", "stop", "status", "engine"]

  connect() {
    this.turns = new Map()
    this.positions = new Map()
    this.depths = new Map()
    this.cursors = new Map(exampleChats.map(chat => [chat.id, 32]))
    this.loading = new Set()
    this.examples = new Map(exampleChats.map(chat => [chat.id, chat]))
    for (const chat of exampleChats) {
      chat.turns.forEach(([prompt, reply], index) => {
        const id = chat.id + "-" + index
        this.turns.set(id, { id, thread: chat.id, time: 32 + index, prompt, reply, engine: "example" })
      })
    }
    try {
      for (const key of Object.keys(localStorage)) {
        if (key.startsWith(PREFIX)) this.readTurn(localStorage.getItem(key))
      }
    } catch { this.storageFailed = true }
    const latestTurn = [...this.turns.values()].filter(turn => turn.engine !== "example").sort((a, b) => b.time - a.time)[0]
    const initialThread = latestTurn?.thread || exampleChats[0].id
    const currentThread = () => new URLSearchParams(location.hash.slice(1)).get("chat") || initialThread
    this.thread = currentThread()
    this.onHash = () => this.open(currentThread())
    window.addEventListener("hashchange", this.onHash)
    const wide = matchMedia("(min-width: 701px)").matches
    this.element.classList.toggle("history-open", wide)
    this.element.querySelector(".relay-menu").setAttribute("aria-expanded", String(wide))
    this.local = "unavailable"
    try { this.engine = localStorage.getItem(ENGINE_KEY) } catch { /* The default stands. */ }
    if (!["server", "local"].includes(this.engine)) this.engine = "auto"
    this.render()
    this.jumpToLatest()
    this.restoreDraft()
    this.connection()
    this.checkLocalModel()
  }

  disconnect() {
    this.stop()
    window.removeEventListener("hashchange", this.onHash)
  }

  get offline() {
    return !navigator.onLine || document.querySelector("[data-inspector-target=offline]")?.checked
  }

  // Where the next reply comes from: "server", "local", or null when nothing can answer.
  get route() {
    const local = this.local === "available"
    if (this.engine === "local") return local ? "local" : null
    if (!this.offline) return "server"
    return this.engine === "auto" && local ? "local" : null
  }

  connection() {
    if (this.offline && this.active?.route === "server") this.stop()
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
    if (!route && this.engine === "local") return "The on-device model isn’t ready. Choose On-device again to download it."
    if (!route) return "Offline. Reconnect to send your draft."
    if (this.storageFailed) return "Browser storage is unavailable. This chat will last for this visit."
    if (route === "local") return (this.offline ? "Offline. " : "") + "Replies come from the model in this browser. Nothing leaves the device."
    return "Replies come from Rails, which may ask a hosted model through RubyLLM."
  }

  async checkLocalModel() {
    this.local = await localModel.availability()
    if (!this.element.isConnected) return
    if (this.engine === "local" && this.local === "unavailable") this.engine = "auto"
    this.connection()
  }

  async chooseEngine(event) {
    this.engine = event.target.value
    try { localStorage.setItem(ENGINE_KEY, this.engine) } catch { this.storageFailed = true }
    this.connection()
    if (this.engine !== "local" || this.local === "available" || this.downloaded != null) return
    this.downloaded = 0
    this.connection()
    try { await localModel.prepare(loaded => { this.downloaded = loaded; this.connection() }) }
    catch { /* The availability check below says where the download stands. */ }
    this.downloaded = null
    await this.checkLocalModel()
  }

  saveDraft() {
    try {
      const key = "instant_record.relay.draft." + this.thread
      if (this.inputTarget.value) {
        history.replaceState(history.state, "", "#chat=" + this.thread)
        sessionStorage.setItem(key, this.inputTarget.value)
      } else sessionStorage.removeItem(key)
    } catch { this.storageFailed = true }
  }

  restoreDraft() {
    try { this.inputTarget.value = sessionStorage.getItem("instant_record.relay.draft." + this.thread) || "" }
    catch { this.inputTarget.value = "" }
  }

  readTurn(json) {
    try {
      const turn = JSON.parse(json)
      if (turn && ["id", "thread", "prompt", "reply", "engine"].every(key => typeof turn[key] === "string") && Number.isFinite(turn.time)) this.turns.set(turn.id, turn)
    } catch { /* Ignore an unreadable record without hiding the rest of the history. */ }
  }

  storage(event) {
    if (!event.key?.startsWith(PREFIX) || !event.newValue) return
    const scroll = this.scrollTarget
    const following = scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight < 65
    const top = scroll.scrollTop
    this.readTurn(event.newValue)
    this.render()
    scroll.scrollTop = following ? scroll.scrollHeight : top
    this.scrolled()
  }

  save(turn) {
    this.turns.set(turn.id, turn)
    try { localStorage.setItem(PREFIX + turn.id, JSON.stringify(turn)) }
    catch { this.storageFailed = true }
  }

  get conversation() {
    return [...this.turns.values()].filter(turn => turn.thread === this.thread).sort((a, b) => a.time - b.time)
  }

  toggleHistory(event) {
    const open = !this.element.classList.contains("history-open")
    this.element.classList.toggle("history-open", open)
    event.currentTarget.setAttribute("aria-expanded", String(open))
  }

  open(id) {
    if (id !== this.thread) {
      this.positions.set(this.thread, this.scrollTarget.scrollTop)
      this.stop()
      this.thread = id
      this.restoreDraft()
      this.render()
      this.scrollTarget.scrollTop = this.positions.get(id) ?? this.scrollTarget.scrollHeight
      this.scrolled()
    }
    if (matchMedia("(max-width: 700px)").matches) {
      this.element.classList.remove("history-open")
      this.element.querySelector(".relay-menu").setAttribute("aria-expanded", "false")
    }
  }

  async loadOlder() {
    const thread = this.thread
    const before = this.cursors.get(thread)
    if (this.loading.has(thread)) return
    const turns = this.conversation
    const depth = this.depths.get(thread) || 8
    const unseen = Math.max(0, turns.length - depth)
    if (unseen) {
      this.prependTurns(turns.slice(Math.max(0, unseen - 8), unseen))
      return
    }
    if (!before) return
    this.loading.add(thread)
    this.olderTarget.textContent = "Loading…"
    try {
      const response = await fetch("/assistant/history?" + new URLSearchParams({ chat: thread, before }))
      if (!response.ok) throw new Error()
      const page = await response.json()
      if (!this.element.isConnected) return
      const rows = page.turns.map(([prompt, reply], i) => {
        const id = thread + "-history-" + (page.before + i)
        const turn = { id, thread, time: page.before + i, prompt, reply, engine: "example" }
        this.turns.set(id, turn)
        return turn
      })
      this.cursors.set(thread, page.before)
      if (this.thread !== thread) return
      this.prependTurns(rows)
    } catch {
      if (this.thread === thread && this.element.isConnected) this.olderTarget.textContent = "Retry loading earlier messages"
    } finally {
      this.loading.delete(thread)
    }
  }

  prependTurns(rows) {
    const anchor = this.transcriptTarget.firstElementChild
    const top = anchor?.getBoundingClientRect().top
    const depth = (this.depths.get(this.thread) || 8) + rows.length
    this.depths.set(this.thread, depth)
    this.transcriptTarget.prepend(...rows.flatMap(turn => this.turnNodes(turn)))
    this.olderTarget.hidden = !this.cursors.get(this.thread) && this.conversation.length <= depth
    this.olderTarget.textContent = "Load earlier messages"
    if (anchor) this.scrollTarget.scrollTop += anchor.getBoundingClientRect().top - top
  }

  scrolled(event) {
    const scroll = this.scrollTarget
    if (event && scroll.scrollTop < 60 && !this.olderTarget.hidden) this.loadOlder()
    this.latestTarget.hidden = scroll.scrollHeight - scroll.clientHeight - scroll.scrollTop < 65
  }

  jumpToLatest() {
    this.scrollTarget.scrollTop = this.scrollTarget.scrollHeight
    this.scrolled()
  }

  newChat() {
    const id = crypto.randomUUID()
    this.open(id)
    location.hash = "chat=" + id
    this.inputTarget.focus()
  }

  render() {
    const turns = this.conversation
    this.titleTarget.textContent = this.examples.get(this.thread)?.title || turns[0]?.prompt || "New chat"
    this.welcomeTarget.hidden = turns.length > 0
    const depth = this.depths.get(this.thread) || 8
    this.olderTarget.hidden = !this.cursors.get(this.thread) && turns.length <= depth
    this.olderTarget.textContent = this.loading.has(this.thread) ? "Loading…" : "Load earlier messages"
    const threads = new Map(exampleChats.map((chat, index) => [chat.id, { first: chat.title, time: -index }]))
    for (const turn of [...this.turns.values()].sort((a, b) => a.time - b.time)) {
      if (turn.engine === "example") continue
      const first = threads.get(turn.thread)?.first || turn.prompt
      threads.set(turn.thread, { first, time: turn.time })
    }
    const threadLink = (id, title) => {
      const link = node("a", "relay-history-link", title)
      link.href = "#chat=" + id
      link.setAttribute("aria-current", id === this.thread ? "page" : "false")
      link.dataset.turbo = "false"
      return link
    }
    const links = [...threads].sort((a, b) => b[1].time - a[1].time).map(([id, info]) => threadLink(id, info.first))
    this.historyTarget.replaceChildren(...(links.length ? links : [node("span", "relay-no-history", "No conversations yet")]))
    this.transcriptTarget.replaceChildren(...turns.slice(-depth).flatMap(turn => this.turnNodes(turn)))
  }

  turnNodes(turn) {
    const user = node("p", "relay-user", turn.prompt)
    const answer = node("article", "relay-answer", "")
    answer.dataset.turn = turn.id
    answer.append(node("h2", "relay-author", this.author(turn)), this.format(turn.reply))
    if (!turn.reply && this.active?.turn.id !== turn.id) answer.append(node("small", "", "No reply was saved."))
    return [user, answer]
  }

  author(turn) {
    // "model" is what a turn from the first on-device version was saved as.
    if (turn.engine === "local" || turn.engine === "model") return LOCAL_NAME
    return turn.engine === "ruby_llm" ? `${turn.model || "Model"} · RubyLLM` : "Demo guide"
  }

  format(text) {
    const body = node("div", "relay-response", "")
    text.split("```").forEach((part, index) => {
      if (!part) return
      if (index % 2) {
        const block = node("pre", "", "")
        block.append(node("code", "", part.replace(/^[\w+-]*\n/, "").trimEnd()))
        const snippet = node("div", "relay-code", "")
        const copy = node("button", "relay-copy", "Copy code")
        copy.type = "button"
        copy.dataset.action = "assistant-chat#copy"
        snippet.append(copy, block)
        body.append(snippet)
      } else {
        for (const paragraph of part.trim().split(/\n\s*\n/)) {
          const lines = paragraph.split("\n")
          const bullets = lines.every(line => line.startsWith("- "))
          const numbered = lines.every(line => /^\d+\. /.test(line))
          if (bullets || numbered) {
            const list = node(bullets ? "ul" : "ol", "", "")
            list.append(...lines.map(line => node("li", "", line.replace(/^(?:-|\d+\.) /, ""))))
            body.append(list)
          } else if (paragraph) body.append(node("p", "", paragraph))
        }
      }
    })
    return body
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

  key(event) {
    if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
      event.preventDefault()
      this.inputTarget.form.requestSubmit()
    }
  }

  suggest(event) {
    const button = event.target.closest("button")
    if (!button || this.active) return
    this.inputTarget.value = button.lastChild.textContent.trim()
    this.saveDraft()
    this.inputTarget.form.requestSubmit()
  }

  async send(event) {
    event.preventDefault()
    const prompt = this.inputTarget.value.trim()
    if (!prompt || this.active) return
    this.saveDraft()
    let route = this.route
    if (!route) return this.connection()
    const clip = text => text.slice(0, HISTORY_TEXT)
    const history = this.conversation.filter(earlier => earlier.reply).slice(-HISTORY_TURNS)
      .map(earlier => [clip(earlier.prompt), clip(earlier.reply)])
    const turn = { id: crypto.randomUUID(), thread: this.thread, time: Date.now(), prompt, reply: "", engine: "guide" }
    const controller = new AbortController()
    this.active = { turn, controller, received: false, route }
    this.inputTarget.readOnly = true
    this.sendTarget.hidden = true
    this.stopTarget.hidden = false
    this.statusTarget.textContent = route === "local" ? "Thinking on this device…" : "Waiting for Rails…"
    this.turns.set(turn.id, turn)
    this.render()
    this.jumpToLatest()
    try {
      if (route === "server") {
        try { await this.askServer(turn, prompt, history, controller.signal) }
        catch (error) {
          // In Auto, a server that can't be reached hands the prompt to the browser's model.
          const fallback = this.active?.turn === turn && !this.active.received && !controller.signal.aborted &&
            this.engine === "auto" && this.local === "available"
          if (!fallback) throw error
          route = this.active.route = "local"
          this.statusTarget.textContent = "Couldn’t reach Rails. Thinking on this device…"
        }
      }
      if (route === "local") await this.askLocal(turn, prompt, history, controller.signal)
    } catch {
      if (this.active?.turn !== turn) return
      this.stop()
      this.statusTarget.textContent = (route === "local" ? "The on-device model couldn’t answer." : "Couldn’t reach the reply service.") + " Your draft is ready to retry."
    } finally {
      if (this.active?.turn === turn) this.finish(turn)
    }
  }

  async askServer(turn, prompt, history, signal) {
    const response = await fetch("/assistant/replies?instant_record_network=1", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ prompt, history }), signal
    })
    if (!response.ok) throw new Error("Server unavailable")
    const { reply, engine, model } = await response.json()
    if (typeof reply !== "string" || !reply) throw new Error("Missing server reply")
    if (this.active?.turn !== turn || this.offline) return
    if (engine === "ruby_llm") Object.assign(turn, { engine, model: String(model || "") })
    this.received(turn, "Replying…")
    for (const chunk of reply.match(/\S+\s*/g) || []) {
      if (signal.aborted || this.active?.turn !== turn) return
      turn.reply += chunk
      this.show(turn)
      await new Promise(resolve => setTimeout(resolve, 15))
    }
  }

  async askLocal(turn, prompt, history, signal) {
    turn.engine = "local"
    const reply = await localModel.reply(prompt, history, { signal, onText: text => {
      if (signal.aborted || this.active?.turn !== turn) return
      if (!this.active.received) this.received(turn, "Replying on this device…")
      turn.reply = text
      this.show(turn)
    } })
    if (!reply) throw new Error("Missing local reply")
  }

  // The first words of a reply arrived: the draft is spent.
  received(turn, status) {
    this.active.received = true
    this.inputTarget.value = ""
    this.saveDraft()
    this.statusTarget.textContent = status
    const author = this.transcriptTarget.querySelector(`[data-turn="${turn.id}"] .relay-author`)
    if (author) author.textContent = this.author(turn)
  }

  show(turn) {
    const scroll = this.scrollTarget
    const pinned = scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight < 65
    this.transcriptTarget.querySelector(`[data-turn="${turn.id}"] .relay-response`)?.replaceWith(this.format(turn.reply))
    if (pinned) scroll.scrollTop = scroll.scrollHeight
  }

  stop() {
    if (!this.active) return
    const { turn, controller } = this.active
    controller.abort()
    if (this.active.received) {
      turn.interrupted = true
      turn.reply = (turn.reply + "\n\nReply stopped.").trim()
    }
    this.finish(turn)
  }

  finish(turn) {
    if (this.active.received) this.save(turn)
    else this.turns.delete(turn.id)
    this.active = null
    this.inputTarget.readOnly = false
    this.sendTarget.hidden = false
    this.stopTarget.hidden = true
    this.render()
    this.connection()
  }

}
