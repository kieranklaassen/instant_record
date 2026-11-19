import { Head, router, usePage } from "@inertiajs/react"
import { useCallback, useEffect, useMemo, useRef, useState } from "react"
import MailList from "../../components/MailList"
import { Clear, Composer, KeyList, Thread } from "../../components/MailReader"
import { useHistory, useKeyboardNavigation, useLiveParam, useLiveSearch, useLiveWindow, useStableRows } from "instant_record"
import { inboxPath, initial, mailRow, replyRow } from "../../lib/mail"

const mailCursor = (row) => ({ created_at: row[5], id: row[0] })
const capitalize = (word) => word[0].toUpperCase() + word.slice(1)
const WRITE = { preserveState: true, preserveScroll: true, async: true }
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

// An ordinary Inertia page: its state is its props and its address.
//
//   mail     the list, a live prop. `limit` in the address says how deep.
//   thread   the conversation the address names, a live prop.
//
// Reading is a partial reload and writing is a form post. InstantRecord sits
// under Inertia (the gem's frontend package): it tells Inertia when to
// reload a live prop, and beside a local database it answers the visit.
export default function Inbox({ member, inbox, inboxes, people, mail, thread, composing }) {
  const scope = useMemo(() => ({ member, inbox }), [member, inbox])
  const { url } = usePage()
  const address = new URL(url, window.location.origin).searchParams.get("thread") || thread.id

  const [open, setOpen] = useState(false)
  const [replyFocus, setReplyFocus] = useState(0)
  const [help, setHelp] = useState(false)
  const [busy, setBusy] = useState(false)
  const [status, setStatus] = useState("")

  // A search is in the address like everything else. The list answers it from
  // the local database at once, and the sync server adds what it holds beyond.
  const [term, setTerm] = useState(mail.q || "")
  const q = useSettled(term.trim(), 200)
  useLiveParam("q", q, { only: MAIL, answered: mail.q || "", omit: (value) => value === "" })
  const search = useLiveSearch(q, { only: MAIL, model: "MailEntry" })
  const history = useHistory()
  const searchBox = useRef(null)

  const rows = useStableRows(mail.rows, mailRow)
  const ids = useMemo(() => rows.map((row) => row.id), [rows])
  const { more, older, failed } = useLiveWindow({ prop: "mail", window: mail, model: "MailEntry", cursor: mailCursor, search: q })
  const now = useRef({})

  useEffect(() => {
    if (failed) setStatus("Older mail is unavailable. Scroll again to retry.")
  }, [failed])

  // Offline with no local database, a reload has nowhere to go. Keep the page.
  useEffect(() => router.on("networkError", (event) => {
    event.preventDefault()
    setStatus("You’re offline. Showing what was loaded.")
  }), [])

  const send = useCallback((fields, options = {}) => {
    router.post("/email", { ...scope, ...fields }, {
      ...WRITE, ...options, onHttpException: () => setStatus("Couldn’t save that."),
    })
  }, [scope])

  // Each write shows at once and is put back if Rails refuses it.
  const read = useCallback((id) => {
    setOpen(true)
    if (!now.current.rows.find((row) => row.id === id)?.unread) return
    send({ kind: "read", parent_id: id }, {
      optimistic: ({ mail }) => ({
        mail: {
          ...mail,
          unread_count: Math.max(mail.unread_count - 1, 0),
          rows: mail.rows.map((row) => (row[0] === id ? row.with(6, "") : row)),
        },
      }),
    })
  }, [send])

  const archive = useCallback((id) => {
    if (!id) return
    setOpen(false)
    send({ kind: "archive", parent_id: id }, {
      optimistic: ({ mail }) => ({ mail: { ...mail, rows: mail.rows.filter((row) => row[0] !== id) } }),
    })
  }, [send])

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

  const back = useCallback(() => {
    const { help, composing } = now.current
    if (help) setHelp(false)
    else if (composing) compose(false)
    else setOpen(false)
  }, [compose])

  const keys = {
    j: () => step(1),
    k: () => step(-1),
    Enter: () => focusedId && openRow(focusedId),
    o: () => focusedId && openRow(focusedId),
    Escape: back,
    u: back,
    e: () => !composing && archive(focusedId),
    r: () => {
      if (composing || !focusedId) return
      read(focusedId)
      setReplyFocus((count) => count + 1)
    },
    c: () => compose(true),
    "/": () => searchBox.current?.focus(),
    "?": () => setHelp((shown) => !shown),
  }

  const { focusedId, focus, move, register } = useKeyboardNavigation({ ids, keys, more, onNeed: older, startAt: address })

  const openRow = useCallback((id) => {
    if (now.current.composing) compose(false)
    focus(id)
    read(id)
  }, [compose, focus, read])

  // With a conversation open, j and k read the next one.
  const step = (by) => {
    const id = move(by)
    if (id && open && !composing) read(id)
  }

  // The address follows the focused row, and `thread` is reloaded for it.
  // Holding j settles first, so the reader is asked for once.
  const wanted = useSettled(composing ? null : focusedId, 60)
  useLiveParam("thread", wanted, { only: THREAD, answered: thread.id })

  // The row paints the message at once; its replies follow with the prop.
  const held = thread.id === focusedId
  const message = composing ? null : rows.find((row) => row.id === focusedId) || (held && !thread.archived ? mailRow(thread.message) : null)
  const replies = held ? thread.replies.map(replyRow) : []
  now.current = { rows, help, composing, url }

  // A message just sent from here is opened when it reaches the list.
  const sent = useRef(null)
  useEffect(() => {
    if (!sent.current || !rows[0] || rows[0].id === sent.current.top) return
    sent.current = null
    openRow(rows[0].id)
  }, [rows, openRow])

  const generate = async () => {
    setBusy(true)
    setStatus("Receiving…")
    try {
      const response = await fetch(`/email/sync/${member}/${inbox}/incoming?instant_record_network=1`, { method: "POST" })
      if (!response.ok) throw new Error()
      setStatus("Email received")
      router.reload({ only: ["mail"] })
    } catch {
      setStatus("Couldn’t receive mail. Check your connection.")
    } finally {
      setBusy(false)
    }
  }

  return (
    <main className="maildesk" data-turbo="false" data-instant-refresh data-detail={String(composing || open)}>
      <Head title="Inbox · Shared inbox" />
      <aside className="mail-rail">
        <div className="mail-brand">
          <span className="mail-mark" aria-hidden="true">
            <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><rect x="3" y="5" width="18" height="14" rx="3" /><path d="M3.5 7.5 12 13l8.5-5.5" /></svg>
          </span>
          Inbox
        </div>
        <button type="button" className="mail-primary mail-compose-link" onClick={keys.c}>
          <svg aria-hidden="true" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M12 20h9" /><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4Z" /></svg>
          Compose
        </button>
        <div className="mail-rail-section">Mailboxes</div>
        <nav aria-label="Mailboxes" className="mail-folders">
          {inboxes.map((box) => (
            <a key={box} href={inboxPath({ member, inbox: box })} aria-current={String(box === inbox)}>
              <svg className="mail-folder-icon" aria-hidden="true" width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M3 13h5l1.5 3h5L16 13h5" /><path d="M5.5 5h13L21 13v5a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-5Z" /></svg>
              {capitalize(box)}
            </a>
          ))}
        </nav>
        <div className="mail-team">
          <div className="mail-rail-section">View as</div>
          <nav aria-label="Demo teammate">
            {people.map(([person, box]) => (
              <a key={person} href={inboxPath({ member: person, inbox: box })} aria-current={String(person === member)}>
                <span className={`mail-avatar avatar-${person}`} aria-hidden="true">{initial(person)}</span>
                {capitalize(person)}
              </a>
            ))}
          </nav>
        </div>
        <button type="button" className="mail-keys-hint" onClick={keys["?"]}><kbd>?</kbd> Keys</button>
      </aside>
      <div className="mail-workspace">
        <header className="mail-bar">
          <h1>Shared inbox</h1>
          <div className="mail-tools">
            <input ref={searchBox} type="search" className="mail-search" placeholder="Search mail" aria-label="Search mail"
              value={term} onChange={(event) => setTerm(event.target.value)} />
            <span role="status">{q && search.partial && !history.done ? "Showing matches on this device. Older mail needs a connection." : status}</span>
            <button type="button" className="mail-incoming" disabled={busy} onClick={generate}>
              <svg aria-hidden="true" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M12 4v11" /><path d="m7 10 5 5 5-5" /><path d="M5 20h14" /></svg>
              Generate incoming email
            </button>
          </div>
        </header>
        <div className="mail-panes">
          <MailList scope={scope} title={`${capitalize(inbox)} inbox`} rows={rows} unreadCount={mail.unread_count} whole={history.done} searching={!!q}
            focusedId={focusedId} openAt={Math.max(ids.indexOf(address), 0)} onOpen={openRow} onEnd={() => older()} register={register} />
          <section className="mail-reader" data-thread={message?.id || ""} data-compose={String(composing)}>
            <button type="button" className="mail-return" onClick={back}>← {capitalize(inbox)}</button>
            {composing ? (
              <Composer scope={scope} onClose={back} onSent={() => compose(false)}
                onSend={() => { sent.current = { top: rows[0]?.id } }} />
            ) : message ? (
              <Thread scope={scope} message={message} replies={replies} replyFocus={replyFocus}
                onMark={(kind) => (kind === "read" ? read(message.id) : send({ kind, parent_id: message.id }))}
                onArchive={() => archive(message.id)} />
            ) : <Clear />}
          </section>
        </div>
      </div>
      {help && <KeyList onClose={() => setHelp(false)} />}
    </main>
  )
}
