import { Controller } from "@hotwired/stimulus"

// The Auth demo's page. It shows the session the server holds, changes it, and
// lets a visitor try the sync server directly. It decides nothing: who may see
// or write a note is decided on the server (AuthNote's syncable_to and
// writable_by), and the notes on the page are whatever this runtime holds.
export default class extends Controller {
  static targets = ["who", "role", "since", "total", "allowed", "person", "signOut",
    "owner", "submit", "formHint", "form", "held", "proof"]
  static values = { sessionUrl: String, signOutUrl: String, bootstrapUrl: String,
    mutationsUrl: String, runtime: String }

  connect() {
    this.session = null
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
    try {
      this.show(await this.request("POST", url, body))
    } catch {
      this.whoTarget.textContent = "That needs the server, and it is out of reach."
      this.personTargets.forEach((button) => (button.disabled = false))
      return
    }
    if (this.runtimeValue === "server") return window.location.reload()

    // A cookie is kept for one origin. A build that syncs with a server on
    // another origin has no session there, and it is better said than hidden.
    const kept = await this.request("GET", this.sessionUrlValue).catch(() => null)
    if (kept && (kept.person?.id || null) !== (this.session.person?.id || null)) {
      this.show(kept)
      this.whoTarget.textContent = "The session cookie did not reach the sync server: it is on another origin than this page."
      return
    }

    // The compiled page is redrawn when the sync pass says records changed.
    // This is only for a pass that changed nothing.
    this.whoTarget.textContent += " Syncing this browser…"
    setTimeout(() => window.location.reload(), 4000)
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
