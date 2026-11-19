// InstantRecord as a transport for Inertia's live props.
//
// A page object names, under `liveProps`, the events each prop listens for,
// and Inertia reloads a prop when one of its events arrives: a partial
// reload, throttled, paused while the tab is hidden, and repeated for every
// live prop when a dropped connection returns. This transport gives it the
// one event InstantRecord has. The gem says
// "instant-record:records-changed" on the window whenever sync or a local
// write touched the local database.
//
// Served by Rails alone there is no local database and so no signal: a slow
// poll stands in for it, and the reload goes to the server.
import { local } from "./window"

const CHANGED = "instant-record:records-changed"
const POLL_MS = 4000

export const liveTransport = {
  subscribe(channel, _event, handler) {
    if (channel.name !== "instant_record") return () => {}
    // No props by value: the signal does not say which records changed, so
    // Inertia asks for the prop again.
    const changed = () => handler({})
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
