// InstantRecord as a transport for Inertia's live props.
//
// A page object names, under `liveProps`, the events each prop listens for,
// and Inertia reloads a prop when one of its events arrives: a partial
// reload, throttled, paused while the tab is hidden, and repeated for every
// live prop when a dropped connection returns.
//
// Here an event is a synced model's name (`live: { mail: MailEntry }` in
// Ruby). The gem says "instant-record:records-changed" on the window whenever
// sync or a local write touched the local database, with the records that
// changed as `detail.changes` ({ type, id } each) when it can list them. A
// prop is reloaded only when a record of one of its models is among them. With
// no list, anything may have changed and every live prop is reloaded.
//
// The handler is given { changes } for its model. That reaches a page as the
// payload of Inertia's `live` event (`router.on("live", ...)`).
//
// Served by Rails alone there is no local database and so no signal: a slow
// poll stands in for it, and the reload goes to the server.
import { local } from "./window.js"

const CHANGED = "instant-record:records-changed"
const POLL_MS = 4000

export const liveTransport = {
  subscribe(channel, model, handler) {
    if (channel.name !== "instant_record") return () => {}
    // No props by value: a prop is whatever the controller makes of its
    // records, so Inertia asks for it again.
    const changed = (event) => {
      const changes = event?.detail?.changes
      if (!changes) return handler({ changes: null })
      const mine = changes.filter((change) => change.type === model)
      if (mine.length) handler({ changes: mine })
    }
    window.addEventListener(CHANGED, changed)
    const poll = local() ? null : setInterval(() => navigator.onLine && changed(), POLL_MS)
    return () => {
      window.removeEventListener(CHANGED, changed)
      if (poll) clearInterval(poll)
    }
  },

  onStatusChange(callback) {
    const up = () => callback(true)
    const down = () => callback(false)
    window.addEventListener("online", up)
    window.addEventListener("offline", down)
    callback(navigator.onLine)
    return () => {
      window.removeEventListener("online", up)
      window.removeEventListener("offline", down)
    }
  },
}
