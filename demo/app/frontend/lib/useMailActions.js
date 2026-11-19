import { router } from "@inertiajs/react"
import { useCallback, useMemo, useRef, useState } from "react"
import { write } from "instant_record"
import { archivedLabel, seenBefore } from "./mail"

const MAIL = ["mail"]
const MAIL_AND_THREAD = ["mail", "thread"]

// One partial reload, answered whatever becomes of it.
const refresh = (only) => new Promise((resolve) => router.reload({ only, async: true, onFinish: resolve }))

// The Inbox's writes. Each is a light form post (the gem's `write`) and
// shows at once: what is on its way is kept here and laid over the props
// (lib/mail.js withOverlay and withPending) until a reload carries it, so
// nothing flickers between a write and its answer and a refused write simply
// lets go.
//
//   notify(text)   says something went wrong
//   hold(action)   from useUndoable: an archive waits there to be undone
//
// Answers { marks, sending, mark, archive, reply }.
export function useMailActions(scope, { notify, hold }) {
  const [marks, setMarks] = useState(() => new Map())
  const [sending, setSending] = useState([])
  const count = useRef(0)

  const post = useCallback((fields, options) => write("/email", { ...scope, ...fields }, options), [scope])

  // Marks `ids` read or unread, one write each, then one reload.
  const mark = useCallback(async (ids, unread) => {
    if (!ids.length) return
    const entry = { unread }
    setMarks((marks) => new Map([...marks, ...ids.map((id) => [id, entry])]))
    try {
      for (const id of ids) await post({ kind: unread ? "unread" : "read", parent_id: id })
    } catch {
      notify(`Couldn’t mark ${ids.length === 1 ? "that" : "everything"} ${unread ? "unread" : "read"}.`)
    }
    await refresh(MAIL_AND_THREAD)
    setMarks((marks) => new Map([...marks].filter(([, other]) => other !== entry)))
  }, [post, notify])

  // Archives `ids` after the undo window. `context` comes back with an undo.
  const archive = useCallback((ids, context) => {
    hold({
      label: archivedLabel(ids.length),
      ids,
      context,
      async commit({ keepalive = false } = {}) {
        // The page is going: send them all now and wait for nothing.
        if (keepalive) return void ids.forEach((id) => post({ kind: "archive", parent_id: id }, { keepalive }).catch(() => {}))
        // All at once, and each able to outlive the page: leaving in the
        // middle must not drop the rest.
        const answers = await Promise.allSettled(ids.map((id) => post({ kind: "archive", parent_id: id }, { keepalive: true })))
        if (answers.some((answer) => answer.status === "rejected")) {
          notify(ids.length === 1 ? "Couldn’t archive that. It’s back in the list." : "Couldn’t archive everything. The rest are back in the list.")
        }
        await refresh(MAIL)
      },
    })
  }, [hold, post, notify])

  // Sends a reply and answers whether it was taken. Until the thread holds
  // it, the reply is in `sending`.
  const reply = useCallback(async (id, body, replies) => {
    const entry = { key: `sending-${++count.current}`, parent: id, author: scope.member, body, at: new Date().toISOString() }
    entry.seen = seenBefore(replies, entry)
    setSending((sending) => [...sending, entry])
    let taken = true
    try {
      await post({ kind: "reply", parent_id: id, body })
      await refresh(MAIL_AND_THREAD)
    } catch {
      taken = false
    }
    setSending((sending) => sending.filter((other) => other !== entry))
    return taken
  }, [scope, post])

  return useMemo(() => ({ marks, sending, mark, archive, reply }), [marks, sending, mark, archive, reply])
}
