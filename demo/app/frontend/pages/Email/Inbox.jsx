import { Head, router, usePage } from "@inertiajs/react"
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react"
import {
  useHistory, useKeyboardNavigation, useLiveParam, useLiveSearch, useLiveWindow, useSelection, useShortcuts, useStableRows, useUndoable,
} from "instant_record"
import Composer from "../../components/mail/Composer"
import EmptyState from "../../components/mail/EmptyState"
import MailList from "../../components/mail/MailList"
import Rail from "../../components/mail/Rail"
import ReplyBox from "../../components/mail/ReplyBox"
import Thread from "../../components/mail/Thread"
import Icon from "../../components/ui/Icon"
import KeyHelp from "../../components/ui/KeyHelp"
import ShortcutHint from "../../components/ui/ShortcutHint"
import Toasts, { useNotices } from "../../components/ui/Toasts"
import { GROUPS, keyOf, mailBindings } from "../../lib/keys"
import { capitalize, firstOf, mailRow, replyRow, withOverlay, withPending } from "../../lib/mail"
import { useDrafts } from "../../lib/useDrafts"
import { useMailActions } from "../../lib/useMailActions"

const mailCursor = (row) => ({ created_at: row[5], id: row[0] })
const THREAD = ["thread"]
const MAIL = ["mail"]

function useSettled(value, ms) {
  const [settled, setSettled] = useState(value)
  useEffect(() => {
    const timer = setTimeout(() => setSettled(value), ms)
    return () => clearTimeout(timer)
  }, [value, ms])
  return settled
}

// The page is held unpainted (mail.css) until the Inbox is whole: the list
// has drawn its rows, or has none to draw. Then it is painted once. A list
// that opens at its top has its rows in the first draw; one that opens
// deeper scrolls first, and the page waits for it.
function usePaintWhenDrawn(count) {
  useLayoutEffect(() => {
    const drawn = () => !!document.querySelector(".mail-row")
    const show = () => { document.documentElement.dataset.mailReady = "" }
    if (count === 0 || drawn()) return show()
    // A list that scrolls to its place draws a row to measure, takes it away
    // and draws the real ones. Rows that are still there a frame on are real.
    let frame
    const watch = new MutationObserver(() => {
      if (!drawn()) return
      cancelAnimationFrame(frame)
      frame = requestAnimationFrame(() => {
        if (!drawn()) return
        watch.disconnect()
        show()
      })
    })
    watch.observe(document.body, { childList: true, subtree: true })
    return () => {
      watch.disconnect()
      cancelAnimationFrame(frame)
    }
  }, [])
}

// An ordinary Inertia page: its state is its props and its address.
//
//   mail     the list, a live prop. `limit` in the address says how deep.
//   thread   the conversation the address names, a live prop.
//
// Reading is a partial reload. InstantRecord sits under Inertia (the gem's
// frontend package): it tells Inertia when to reload a live prop, and beside
// a local database it answers the visit.
//
// This file is composition. The writes are lib/useMailActions.js, the keys
// are lib/keys.js, and what is on its way is laid over the props by
// lib/mail.js.
export default function Inbox({ member, inbox, inboxes, people, mail, thread, composing }) {
  const scope = useMemo(() => ({ member, inbox }), [member, inbox])
  const { url } = usePage()
  const address = new URL(url, window.location.origin).searchParams.get("thread") || thread.id

  const [open, setOpen] = useState(false)
  const [replying, setReplying] = useState(false)
  const [replyVersion, setReplyVersion] = useState(0)
  const [help, setHelp] = useState(false)
  const [busy, setBusy] = useState(false)
  const [restore, setRestore] = useState(null)
  const sender = useRef(null)
  const reader = useRef(null)

  const { notices, notify, dismiss } = useNotices()
  const undoable = useUndoable()
  const actions = useMailActions(scope, { notify, hold: undoable.hold })
  const drafts = useDrafts(scope)

  // A search is in the address like everything else. The list answers it from
  // the local database at once, and the sync server adds what it holds beyond.
  const [term, setTerm] = useState(mail.q || "")
  const q = useSettled(term.trim(), 200)
  useLiveParam("q", q, { only: MAIL, answered: mail.q || "", omit: (value) => value === "" })
  const search = useLiveSearch(q, { only: MAIL, model: "MailEntry" })
  const history = useHistory()
  const searchBox = useRef(null)

  const loaded = useStableRows(mail.rows, mailRow)
  const { rows, unreadCount } = useMemo(
    () => withOverlay(loaded, mail.unread_count, { held: undoable.held, marks: actions.marks }),
    [loaded, mail.unread_count, undoable.held, actions.marks],
  )
  const ids = useMemo(() => rows.map((row) => row.id), [rows])
  usePaintWhenDrawn(rows.length)
  const { more, older, failed } = useLiveWindow({ prop: "mail", window: mail, model: "MailEntry", cursor: mailCursor, search: q })
  const { focusedId, focus, move, register } = useKeyboardNavigation({ ids, more, onNeed: older, startAt: address })
  const selection = useSelection(ids)
  const now = useRef({})

  useEffect(() => {
    if (failed) notify("Older mail is unavailable. Scroll again to retry.")
  }, [failed, notify])

  // Offline with no local database, a reload has nowhere to go. Keep the page.
  useEffect(() => router.on("networkError", (event) => {
    event.preventDefault()
    notify("You’re offline. Showing what was loaded.")
  }), [notify])

  // The address follows the focused row, and `thread` is reloaded for it.
  // Holding j settles first, so the reader is asked for once.
  const wanted = useSettled(composing ? null : focusedId, 60)
  useLiveParam("thread", wanted, { only: THREAD, answered: thread.id })

  // The row paints the message at once; its replies follow with the prop.
  const held = thread.id === focusedId
  const message = composing ? null : rows.find((row) => row.id === focusedId) || (held && !thread.archived && !undoable.held.has(thread.id) ? mailRow(thread.message) : null)
  const replies = useMemo(() => {
    const answered = held ? thread.replies.map(replyRow) : []
    return withPending(answered, actions.sending.filter((entry) => entry.parent === focusedId))
  }, [held, thread.replies, actions.sending, focusedId])
  now.current = { rows, ids, focusedId, open, composing, url, message, replies, selected: selection.selected }

  // A conversation in the reader is read. Moving through the list with the
  // reader open reads each one the keys settle on.
  useEffect(() => {
    if (!open || composing || !wanted || wanted !== focusedId) return
    if (now.current.rows.find((row) => row.id === wanted)?.unread) actions.mark([wanted], false)
  }, [open, composing, wanted, focusedId, actions.mark])

  // A reply box belongs to one conversation.
  useEffect(() => setReplying(false), [focusedId])

  // What an action applies to: the selection, or else the focused row.
  const targets = () => {
    const { ids, focusedId, selected } = now.current
    if (selected.size) return ids.filter((id) => selected.has(id))
    return focusedId ? [focusedId] : []
  }

  // Composing is in the address and needs nothing from the server.
  const compose = useCallback((composing) => {
    setOpen(false)
    const address = new URL(now.current.url, window.location.origin)
    if (composing) address.searchParams.set("compose", "1")
    else address.searchParams.delete("compose")
    router.replace({
      url: address.pathname + address.search,
      props: (props) => ({ ...props, composing }),
      preserveState: true,
      preserveScroll: true,
    })
  }, [])

  const openRow = useCallback((id) => {
    if (now.current.composing) compose(false)
    focus(id)
    setOpen(true)
  }, [compose, focus])

  const archive = (list = targets()) => {
    if (!list.length) return
    const { ids, focusedId, open } = now.current
    const gone = new Set(list)
    // Focus goes to the top of the block, so it lands on the row that takes its place.
    if (gone.has(focusedId)) focus(firstOf(ids, gone))
    actions.archive(list, { focus: focusedId, open })
    selection.clear()
  }

  const undo = () => {
    const action = undoable.undo()
    if (action) setRestore(action.context)
  }

  // An undone archive puts focus and the reader back once its rows return.
  useEffect(() => {
    if (!restore) return
    if (restore.focus && !ids.includes(restore.focus)) return
    if (restore.focus) focus(restore.focus)
    setOpen(restore.open)
    setRestore(null)
  }, [restore, ids, focus])

  // `only` is the reader's own button: that conversation, whatever is selected.
  const mark = (unread, only) => {
    const { rows, selected } = now.current
    const state = new Map(rows.map((row) => [row.id, row.unread]))
    const list = (only || targets()).filter((id) => state.get(id) !== unread)
    if (unread && (only || !selected.size)) setOpen(false)
    actions.mark(list, unread)
  }

  // Stable, so a row that did not change is not drawn again (MailRow is memoized).
  const { toggle, extendTo } = selection
  const select = useCallback((id, { range } = {}) => {
    if (range) extendTo(id, now.current.focusedId)
    else toggle(id)
    focus(id)
  }, [toggle, extendTo, focus])

  const reply = () => {
    if (!now.current.message) return
    setOpen(true)
    setReplying(true)
  }

  const sendReply = (body, { archive: thenArchive }) => {
    const { id } = now.current.message
    setReplying(false)
    actions.reply(id, body, now.current.replies.filter((reply) => !reply.pending)).then((taken) => {
      if (taken) return thenArchive && archive([id])
      // Something may have been typed there since: keep both.
      const since = drafts.read(id)
      drafts.save(id, since ? `${body}\n\n${since}` : body)
      notify("Couldn’t send your reply. It’s back in the box.")
      if (now.current.focusedId !== id) return
      setReplyVersion((version) => version + 1)
      setReplying(true)
    })
  }

  const back = () => {
    if (now.current.selected.size) selection.clear()
    else if (now.current.composing) compose(false)
    else setOpen(false)
  }

  const bindings = mailBindings({
    step: move,
    enter: () => (now.current.open && !composing ? reply() : focusedId && openRow(focusedId)),
    open: () => focusedId && openRow(focusedId),
    back,
    scroll: (by) => reader.current?.scrollBy({ top: by * reader.current.clientHeight * 0.85, behavior: "smooth" }),
    archive,
    markUnread: () => mark(true),
    markRead: () => mark(false),
    undo,
    help: () => setHelp((shown) => !shown),
    reply,
    send: (options) => sender.current?.(options),
    compose: () => compose(true),
    search: () => searchBox.current?.focus(),
    select: () => focusedId && selection.toggle(focusedId),
    extend: (by) => {
      const from = focusedId
      const id = move(by)
      if (id) selection.extendTo(id, from)
    },
    selectAll: selection.all,
  }, {
    composing: () => composing,
    writing: () => !!sender.current,
    replying: () => !!sender.current && !composing,
  })
  useShortcuts(bindings)
  const keys = {
    reply: keyOf(bindings, "reply"), archive: keyOf(bindings, "archive"), unread: keyOf(bindings, "unread"), read: keyOf(bindings, "read"),
    send: keyOf(bindings, "send"), sendArchive: keyOf(bindings, "send-archive"), back: keyOf(bindings, "back"),
  }

  // A message just sent from here is opened when it reaches the list.
  const sent = useRef(null)
  useEffect(() => {
    if (!sent.current || !rows[0] || rows[0].id === sent.current.top) return
    sent.current = null
    openRow(rows[0].id)
  }, [rows, openRow])

  const generate = async () => {
    setBusy(true)
    try {
      const response = await fetch(`/email/incoming?member=${encodeURIComponent(member)}&inbox=${encodeURIComponent(inbox)}&instant_record_network=1`, { method: "POST" })
      if (!response.ok) throw new Error()
      router.reload({ only: ["mail"], async: true })
    } catch {
      notify("Couldn’t receive mail. Check your connection.")
    } finally {
      setBusy(false)
    }
  }

  return (
    <main className="maildesk" data-turbo="false" data-instant-refresh data-detail={String(composing || open)}>
      <Head title="Inbox · Shared inbox" />
      <Rail member={member} inbox={inbox} inboxes={inboxes} people={people}
        composeKey={keyOf(bindings, "compose")} helpKey={keyOf(bindings, "help")}
        onCompose={() => compose(true)} onHelp={() => setHelp(true)} />
      <div className="mail-workspace">
        <header className="mail-bar">
          <h1>Shared inbox</h1>
          <div className="mail-tools">
            <input ref={searchBox} type="search" className="mail-search" placeholder="Search mail" aria-label="Search mail"
              value={term} onChange={(event) => setTerm(event.target.value)} />
            <span role="status">{q && search.partial && !history.done ? "Showing matches on this device. Older mail needs a connection." : ""}</span>
            <button type="button" className="mail-incoming" disabled={busy} onClick={generate}>
              <Icon name="incoming" size={15} />
              {busy ? "Receiving…" : "Generate incoming email"}
            </button>
          </div>
        </header>
        <div className="mail-panes">
          <MailList scope={scope} title={`${capitalize(inbox)} inbox`} rows={rows} unreadCount={unreadCount} whole={history.done} searching={!!q}
            focusedId={focusedId} open={open && !composing} selected={selection.selected} keys={keys}
            openAt={Math.max(ids.indexOf(address), 0)} onOpen={openRow} onSelect={select} onEnd={() => older()} register={register}
            bulk={{ onArchive: () => archive(), onRead: () => mark(false), onUnread: () => mark(true), onClear: selection.clear }} />
          <section className="mail-reader" data-thread={message?.id || ""} data-compose={String(composing)}>
            <button type="button" className="mail-return" onClick={back}><Icon name="back" size={14} /> {capitalize(inbox)}</button>
            {composing ? (
              <Composer scope={scope} drafts={drafts} sender={sender} keys={keys} onClose={back} onSent={() => compose(false)}
                onSend={() => { sent.current = { top: rows[0]?.id } }}
                onFail={() => { sent.current = null; notify("Couldn’t send that. It’s still here.") }} />
            ) : message ? (
              <>
                <Thread key={message.id} message={message} replies={replies} keys={keys} scroller={reader}
                  onReply={reply} onUnread={() => mark(true, [message.id])} onArchive={() => archive([message.id])} />
                <ReplyBox key={`${message.id}:${replyVersion}`} id={message.id} address={message.address} open={replying}
                  keys={keys} drafts={drafts} sender={sender}
                  onOpen={reply} onClose={() => setReplying(false)} onSend={sendReply} />
              </>
            ) : <EmptyState />}
          </section>
        </div>
      </div>
      <Toasts notices={notices} pending={undoable.pending} undoKey={keyOf(bindings, "undo")} onUndo={undo} onDismiss={dismiss} />
      <ShortcutHint />
      {help && <KeyHelp bindings={bindings} groups={GROUPS} onClose={() => setHelp(false)} />}
    </main>
  )
}
