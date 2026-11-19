import { Controller } from "@hotwired/stimulus"

// The Auth demo's page. It shows the session the server holds, changes it, and
// lets a visitor try the sync server directly. It decides nothing: who may see
// or write a note is decided on the server (AuthNote's syncable_to and
// writable_by), and the notes on the page are whatever this runtime holds.
export default class extends Controller {
  static targets = ["who", "role", "since", "total", "allowed", "person", "signOut",
    "owner", "submit", "formHint", "form", "held", "proof", "list", "empty", "pending"]
  static values = { sessionUrl: String, signOutUrl: String, bootstrapUrl: String,
    mutationsUrl: String, runtime: String }

  connect() {
    this.session = null
    this.showEmpty()
    this.load()
  }

  async load() {
    try {
      this.show(await this.request("GET", this.sessionUrlValue))
    } catch {
      this.whoTarget.textContent = "The server is out of reach, so nobody can say who you are."
      this.lock("Sign in needs the server.")
    }
  }

  signIn(event) {
    this.change(this.sessionUrlValue, { person: event.currentTarget.dataset.person })
  }

  signOut() {
    this.change(this.signOutUrlValue, {})
  }

  // The session changes on the server. The browser's database follows on its
  // next sync: the server tells it to drop what it held and start again as
  // whoever is signed in now.
  async change(url, body) {
    this.personTargets.forEach((button) => (button.disabled = true))
    this.proofTarget.replaceChildren() // what the server told someone else
    try {
      this.show(await this.request("POST", url, body))
    } catch {
      this.whoTarget.textContent = "That needs the server, and it is out of reach."
      this.personTargets.forEach((button) => (button.disabled = false))
      return
    }
    // Rails holds the notes and the session both: ask for the page as the
    // person now signed in, and fold it in.
    if (this.runtimeValue === "server") return this.refresh()

    // A cookie is kept for one origin. A build that syncs with a server on
    // another origin has no session there, and it is better said than hidden.
    const kept = await this.request("GET", this.sessionUrlValue).catch(() => null)
    if (kept && (kept.person?.id || null) !== (this.session.person?.id || null)) {
      this.show(kept)
      this.whoTarget.textContent = "The session cookie did not reach the sync server: it is on another origin than this page."
      return
    }

    // This browser's database follows on its next sync pass, and the page is
    // told when it has (refresh, below). The timer is for a pass that changed
    // nothing.
    this.whoTarget.textContent += " Syncing this browser…"
    clearTimeout(this.settling)
    this.settling = setTimeout(() => this.refresh(), 4000)
  }

  // A form in the notes section: a new note, or a Delete. It is posted as the
  // form would post itself, and the answer is this page with the write made.
  async write(event) {
    event.preventDefault()
    const form = event.target
    const body = new URLSearchParams(new FormData(form))
    const writing = form === this.formTarget
    try {
      const response = await fetch(form.action, { method: "POST", body, credentials: "same-origin" })
      if (!response.ok) throw new Error(`write failed: ${response.status}`)
      this.fold(await response.text())
      if (writing) {
        form.querySelectorAll("input[type=text], textarea").forEach((field) => (field.value = ""))
        form.querySelector("input[type=text]").focus()
      }
    } catch {
      form.submit() // the plain form still works
    }
  }

  // The page again, as it stands now, folded into the one on screen.
  async refresh() {
    clearTimeout(this.settling)
    if (this.refreshing) return
    this.refreshing = true
    try {
      const response = await fetch(window.location.pathname, { credentials: "same-origin" })
      if (response.ok) this.fold(await response.text())
      if (this.session) this.show(this.session)
    } catch {
      // keep what is on screen until the next signal
    } finally {
      this.refreshing = false
    }
  }

  fold(html) {
    const fresh = new DOMParser().parseFromString(html, "text/html")
    const list = fresh.querySelector("[data-auth-target=list]")
    if (!list) return
    foldRows(this.listTarget, list)
    const held = fresh.querySelector("[data-auth-target=held]")
    if (held) this.heldTarget.textContent = held.textContent
    const pending = fresh.querySelector("[data-auth-target=pending]")
    if (pending && this.hasPendingTarget) this.pendingTarget.textContent = pending.textContent
    this.showEmpty()
    // A new session has a new forgery token, and this page is never reloaded
    // to pick it up: take it from the fresh page for the form that stays.
    const token = fresh.querySelector("[data-auth-target=form] input[name=authenticity_token]")
    const mine = this.formTarget.querySelector("input[name=authenticity_token]")
    if (token && mine) mine.value = token.value
  }

  showEmpty() {
    this.emptyTarget.hidden = this.listTarget.querySelector(".auth-note:not(.auth-leave)") !== null
  }

  show(session) {
    this.session = session
    const person = session.person
    this.whoTarget.textContent = person ? `Signed in as ${person.name}.` : "Signed out."
    this.roleTarget.textContent = person ? person.role : "–"
    this.sinceTarget.textContent = session.signed_in_at ? new Date(session.signed_in_at).toLocaleTimeString() : "–"
    this.totalTarget.textContent = session.notes_on_server
    this.allowedTarget.textContent = session.notes_for_you
    this.personTargets.forEach((button) => {
      button.disabled = false
      button.setAttribute("aria-pressed", person && button.dataset.person === person.id ? "true" : "false")
    })
    this.signOutTarget.hidden = !person
    this.ownerTarget.value = person ? person.id : ""
    if (person) {
      this.submitTarget.disabled = false
      this.formHintTarget.textContent = `It will be written as ${person.name}.`
    } else {
      this.lock("Sign in to write a note.")
    }
  }

  lock(reason) {
    this.submitTarget.disabled = true
    this.formHintTarget.textContent = reason
  }

  // What the sync server sends this browser when asked for everything.
  async ask() {
    try {
      const body = await this.request("GET", this.bootstrapUrlValue)
      const notes = body.records.filter((record) => record.type === "AuthNote")
      const lines = [`The server holds ${this.session ? this.session.notes_on_server : "some"} notes. Asked for everything, it sent this browser ${notes.length}:`]
      notes.forEach((note) => lines.push(`${note.attributes.title} (${note.attributes.audience})`))
      this.report(lines)
    } catch {
      this.report(["The sync server is out of reach."])
    }
  }

  // A write in someone else's name, posted straight to the sync server.
  async forge() {
    const me = this.session && this.session.person
    const victim = me && me.id === "cleo" ? "ben" : "cleo"
    const id = crypto.randomUUID()
    const now = new Date().toISOString()
    const mutation = { id: crypto.randomUUID(), record_type: "AuthNote", record_id: id, operation: "create",
      changes: { id, title: "Forged", body: "", audience: "everyone", owner_id: victim, created_at: now, updated_at: now } }
    try {
      const body = await this.request("POST", this.mutationsUrlValue, { mutations: [mutation] })
      const result = body.results[0]
      this.report([
        `${me ? me.name : "A signed-out browser"} tried to create a public note written by ${victim}.`,
        `The server answered: ${result.status}${result.reason ? `, ${result.reason}` : ""}.`,
      ])
    } catch {
      this.report(["The sync server is out of reach."])
    }
  }

  report(lines) {
    this.proofTarget.replaceChildren(...lines.map((line) => {
      const row = document.createElement("p")
      row.textContent = line
      return row
    }))
  }

  disconnect() {
    clearTimeout(this.settling)
  }

  async request(method, url, body) {
    const options = { method, credentials: "same-origin" }
    if (method === "POST") {
      options.headers = { "Content-Type": "application/json" }
      options.body = JSON.stringify(body)
    }
    const response = await fetch(url, options)
    if (!response.ok) throw new Error(`${method} ${url}: ${response.status}`)
    return response.json()
  }
}

// The fresh list folded into the one on screen, by note id. A note that stays
// keeps its element, so nothing blinks; one that arrives eases in, and one
// that leaves closes up before it is removed.
const foldRows = (current, fresh) => {
  const incoming = [...fresh.children].filter((row) => row.dataset.id)
  const staying = new Set(incoming.map((row) => row.dataset.id))
  const existing = new Map()
  for (const row of [...current.children]) {
    if (row.classList.contains("auth-leave")) continue
    if (staying.has(row.dataset.id)) existing.set(row.dataset.id, row)
    else leave(row)
  }

  let anchor = null
  for (const row of incoming) {
    let node = existing.get(row.dataset.id)
    if (node) {
      // The forms inside carry a token that differs on every render, so the
      // contents are swapped whenever they differ and the element is kept.
      if (node.innerHTML !== row.innerHTML) node.replaceChildren(...row.childNodes)
      node.className = [...row.classList, ...(node.classList.contains("auth-enter") ? ["auth-enter"] : [])].join(" ")
    } else {
      node = document.importNode(row, true)
      node.classList.add("auth-enter")
      node.addEventListener("animationend", () => node.classList.remove("auth-enter"), { once: true })
    }
    if (anchor ? anchor.nextElementSibling !== node : current.firstElementChild !== node) {
      anchor ? anchor.after(node) : current.prepend(node)
    }
    anchor = node
  }
}

const leave = (row) => {
  row.style.height = `${row.offsetHeight}px`
  row.classList.add("auth-leave")
  // Read back, so the height above is where the transition starts.
  row.offsetHeight // eslint-disable-line no-unused-expressions
  row.style.height = "0px"
  const done = () => row.remove()
  row.addEventListener("transitionend", done, { once: true })
  setTimeout(done, 400)
}
