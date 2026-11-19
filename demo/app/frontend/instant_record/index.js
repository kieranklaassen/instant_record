// InstantRecord for an Inertia page in React.
//
//   createInertiaApp({ ...instantRecord(), resolve, setup })
//
// The page stays an ordinary Inertia page: props in, visits out. These make
// its live props follow the local database and, in the compiled runtime, let
// that database answer its visits.
import { localHttpClient } from "./http"
import { liveTransport } from "./live"
import { local } from "./window"

export const instantRecord = () => ({ live: liveTransport, ...(local() ? { http: localHttpClient } : {}) })

export { localHttpClient, liveTransport }
export { local, useLiveParam, useLiveWindow, useStableRows, widenWindow } from "./window"
export { resolveFocus, useKeyboardNavigation } from "./keyboard"
export { default as LiveList } from "./LiveList"
