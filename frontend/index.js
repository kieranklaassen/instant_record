// InstantRecord for an Inertia page in React. It ships in the gem:
//
//   npm install "$(bundle show instant_record)/frontend"
//
//   import { instantRecord } from "instant_record"
//   createInertiaApp({ ...instantRecord(), resolve, setup })
//
// The page stays an ordinary Inertia page: props in, visits out. These make
// its live props follow the local database and, in the compiled runtime, let
// that database answer its visits.
import { localHttpClient } from "./http.js"
import { liveTransport } from "./live.js"
import { local } from "./window.js"

// The compiled runtime's own templates place the first page in an attribute
// of the root element, where plain escaping is enough.
const pageInAttribute = (id = "app") => {
  const page = document.getElementById(id)?.dataset.page
  return page ? { page: JSON.parse(page) } : {}
}

export const instantRecord = () => ({
  live: liveTransport,
  ...(local() ? { http: localHttpClient, ...pageInAttribute() } : {}),
})

export { localHttpClient, liveTransport }
export { local, useLiveParam, useLiveWindow, useStableRows, widenWindow } from "./window.js"
export { resolveFocus } from "./focus.js"
export { useKeyboardNavigation } from "./keyboard.js"
export { default as LiveList } from "./LiveList.js"
