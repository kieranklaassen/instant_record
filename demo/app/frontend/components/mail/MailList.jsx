import { useState } from "react"
import { LiveList } from "instant_record"
import BulkBar from "./BulkBar"
import MailRow from "./MailRow"

// The whole mailbox as one list. Only the rows on screen are in the page.
// One object a depth, so a memoized row is not drawn again for an equal one.
const PAGE = 50
const kept = new Map()
const depths = (index) => {
  const limit = index < PAGE ? 0 : Math.ceil((index + 1) / PAGE) * PAGE
  if (!kept.has(limit)) kept.set(limit, limit ? { limit } : {})
  return kept.get(limit)
}

export default function MailList({ scope, title, rows, unreadCount, whole, searching, focusedId, open, selected, keys, onOpen, onSelect, onEnd, register, openAt, bulk }) {
  const [atTop, setAtTop] = useState(true)
  return (
    <section className="mail-list" aria-label="Conversations" data-selecting={String(selected.size > 0)} data-scrolled={String(!atTop)}>
      {selected.size > 0 ? (
        <BulkBar count={selected.size} keys={keys} {...bulk} />
      ) : (
        <header>
          <h2>{title}</h2>
          {/* Counted in the local database: a floor until the whole inbox is in it. */}
          {unreadCount > 0 && <span className="mail-unread-count" title={whole ? undefined : "Counted in the mail on this device so far"}>{unreadCount}{whole ? "" : "+"} unread</span>}
        </header>
      )}
      {rows.length === 0 && <p className="mail-empty-list">{searching ? "No conversations match." : "No open conversations."}</p>}
      <LiveList className="mail-scroll" rows={rows} onEnd={onEnd} register={register} openAt={openAt} onTop={setAtTop}>
        {(row, index) => (
          <div className="mail-item">
            <MailRow row={row} scope={scope} depth={depths(index)} focused={row.id === focusedId} open={open && row.id === focusedId}
              selected={selected.has(row.id)} onOpen={onOpen} onSelect={onSelect} />
          </div>
        )}
      </LiveList>
    </section>
  )
}
