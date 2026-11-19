import { memo } from "react"
import { LiveList } from "instant_record"
import { avatarClass, inboxPath, initial, shortTime } from "../lib/mail"

// Memoized: an answer that changes one conversation redraws one row.
// A row's link names the depth that holds it, as the address does, so the link
// opens the same conversation in a browser that has not scrolled that far.
const PAGE = 50
const depth = (index) => (index < PAGE ? {} : { limit: Math.ceil((index + 1) / PAGE) * PAGE })

const Row = memo(function Row({ row, scope, depth, focused, onOpen }) {
  const open = (event) => {
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.button) return
    event.preventDefault()
    onOpen(row.id)
  }
  return (
    <a className="mail-row" href={inboxPath(scope, { thread: row.id, ...depth })} onClick={open} data-id={row.id} data-at={row.at}
      data-unread={String(row.unread)} data-focused={String(focused)} aria-current={String(focused)}>
      <span className={avatarClass(row.author)} aria-hidden="true">{initial(row.author)}</span>
      <span className="mail-row-text">
        {row.unread && <span className="visually-hidden">Unread. </span>}
        <span className="mail-row-meta">
          <b>{row.outside ? row.author : `To ${row.address}`}</b>
          <time dateTime={row.at} title={new Date(row.at).toLocaleString()}>{shortTime(row.at)}</time>
        </span>
        <strong>{row.subject}</strong>
        <span className="mail-snippet">{row.body}</span>
      </span>
    </a>
  )
})

// The whole mailbox as one list. Only the rows on screen are in the page.
// One object a depth, so a memoized row is not drawn again for an equal one.
const kept = new Map()
const depths = (index) => {
  const value = depth(index)
  const key = value.limit || 0
  if (!kept.has(key)) kept.set(key, value)
  return kept.get(key)
}

export default function MailList({ scope, title, rows, unreadCount, focusedId, openAt, onOpen, onEnd, register }) {
  return (
    <section className="mail-list" aria-label="Conversations">
      <header>
        <h2>{title}</h2>
        {unreadCount > 0 && <span className="mail-unread-count">{unreadCount} unread</span>}
      </header>
      {rows.length === 0 && <p className="mail-empty-list">No open conversations.</p>}
      <LiveList className="mail-scroll" rows={rows} onEnd={onEnd} register={register} openAt={openAt}>
        {(row, index) => (
          <div className="mail-item">
            <Row row={row} scope={scope} depth={depths(index)} focused={row.id === focusedId} onOpen={onOpen} />
          </div>
        )}
      </LiveList>
    </section>
  )
}
