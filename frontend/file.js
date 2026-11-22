// A record's file, for a page that shows or plays it.
//
//   const files = fileStore()                          // once, outside the component
//   const { url, status, progress } = useFile(files, "Recording", recording.id)
//   return status === "ready" ? <audio src={url} controls /> : <Waiting status={status} progress={progress} />
//
// The file is read from this browser when it is here, with or without a
// connection, and fetched from the server and kept when it is not. `status`
// is one of:
//
//   loading   reading it, or fetching it (`progress` goes from 0 to 1)
//   ready     `url` and `file` are set
//   missing   the server does not hold it: its upload has not finished on
//             the device that made it
//   offline   it is not here and there is no connection to fetch it over
//   error     anything else, as `error`
//
// A file that could not be had is asked for again when the connection
// returns, and when `retry` is called.
import { useCallback, useEffect, useRef, useState } from "react"

const NONE = { status: "none", url: null, file: null, progress: 0, error: null }
const LOADING = { status: "loading", url: null, file: null, progress: 0, error: null }

// What a failed open is called. Out here so it can be tested without React.
export function failure(error, online = globalThis.navigator?.onLine !== false) {
  if (error?.name === "FileMissing") return "missing"
  return online ? "error" : "offline"
}

export function useFile(store, type, id) {
  const [state, setState] = useState(id ? LOADING : NONE)
  const [attempt, setAttempt] = useState(0)
  const status = useRef(state.status)
  status.current = state.status
  const retry = useCallback(() => setAttempt((count) => count + 1), [])

  useEffect(() => {
    if (!id) return setState(NONE)
    let live = true
    let url = null
    setState(LOADING)
    store.open(type, id, {
      onProgress: ({ received, size }) => live && setState((now) => ({ ...now, progress: received / size })),
    }).then((file) => {
      if (!live) return
      url = URL.createObjectURL(file)
      setState({ status: "ready", url, file, progress: 1, error: null })
    }, (error) => {
      if (live) setState({ ...NONE, status: failure(error), error })
    })
    return () => {
      live = false
      if (url) URL.revokeObjectURL(url)
    }
  }, [store, type, id, attempt])

  useEffect(() => {
    const online = () => ["offline", "error", "missing"].includes(status.current) && retry()
    window.addEventListener("online", online)
    return () => window.removeEventListener("online", online)
  }, [retry])

  return { ...state, retry }
}
