import { useMemo } from "react"
import { draftKey } from "./mail"

// What is being written, kept for the session: a reply per conversation and
// the new-conversation form. Nothing here reaches the server. Where the
// browser offers no storage a draft simply does not outlive its form.
export function useDrafts(scope) {
  return useMemo(() => {
    const store = (act, fallback) => {
      try {
        return act(window.sessionStorage)
      } catch {
        return fallback
      }
    }
    return {
      read: (id) => store((kept) => kept.getItem(draftKey(scope, id)), null) || "",
      save: (id, text) => store((kept) => (text ? kept.setItem(draftKey(scope, id), text) : kept.removeItem(draftKey(scope, id)))),
      clear: (id) => store((kept) => kept.removeItem(draftKey(scope, id))),
    }
  }, [scope])
}
