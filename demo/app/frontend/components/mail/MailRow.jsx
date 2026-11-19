import { memo } from "react"
import { inboxPath, shortTime } from "../../lib/mail"
import Avatar from "../ui/Avatar"

// One conversation in the list. Four states show at once: focused (the ring
// the keys move), open (in the reader), selected (its box ticked) and unread.
//
// Memoized: an answer that changes one conversation redraws one row.
// `depth` is the list depth that holds the row; the link names it, as the
// address does, so it opens the same conversation in a browser that has not
// scrolled that far.
export default memo(function MailRow({ row, scope, depth, focused, open, selected, onOpen, onSelect }) {
  const sender = row.outside ? row.author : `To ${row.address}`

  const click = (event) => {
    if (event.metaKey || event.ctrlKey || event.button) return
    event.preventDefault()
    if (event.shiftKey) onSelect(row.id, { range: true })
    else onOpen(row.id)
  }

  return (
    <div className="mail-row" data-id={row.id} data-at={row.at} data-unread={String(row.unread)}
      data-focused={String(focused)} data-open={String(open)} data-selected={String(selected)}>
      <label className="mail-pick">
        <input type="checkbox" checked={selected} aria-label={`Select the conversation from ${sender}`}
          onChange={() => {}} onClick={(event) => onSelect(row.id, { range: event.shiftKey })} />
        <Avatar name={row.author} />
      </label>
      <a className="mail-row-link" href={inboxPath(scope, { thread: row.id, ...depth })} onClick={click} aria-current={String(open)}>
        {row.unread && <span className="visually-hidden">Unread. </span>}
        <span className="mail-row-meta">
          <b data-address={String(!row.outside)}>{sender}</b>
          <time dateTime={row.at} title={new Date(row.at).toLocaleString()}>{shortTime(row.at)}</time>
        </span>
        <strong>{row.subject}</strong>
        <span className="mail-snippet">{row.body}</span>
      </a>
    </div>
  )
})
