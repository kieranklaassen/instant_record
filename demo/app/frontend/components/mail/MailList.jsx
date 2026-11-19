import { useState } from "react"
import { LiveList } from "instant_record"
import BulkBar from "./BulkBar"
import MailRow from "./MailRow"

// The whole mailbox as one list. Only the rows on screen are in the page.
export default function MailList({ scope, title, rows, unreadCount, focusedId, open, selected, keys, onOpen, onSelect, onEnd, register, openAt, bulk }) {
  const [atTop, setAtTop] = useState(true)
  return (
    <section className="mail-list" aria-label="Conversations" data-selecting={String(selected.size > 0)} data-scrolled={String(!atTop)}>
      {selected.size > 0 ? (
        <BulkBar count={selected.size} keys={keys} {...bulk} />
      ) : (
        <header>
          <h2>{title}</h2>
          {unreadCount > 0 && <span className="mail-unread-count">{unreadCount} unread</span>}
        </header>
      )}
      {rows.length === 0 && <p className="mail-empty-list">No open conversations.</p>}
      <LiveList className="mail-scroll" rows={rows} onEnd={onEnd} register={register} openAt={openAt} onTop={setAtTop}>
        {(row) => (
          <div className="mail-item">
            <MailRow row={row} scope={scope} focused={row.id === focusedId} open={open && row.id === focusedId}
              selected={selected.has(row.id)} onOpen={onOpen} onSelect={onSelect} />
          </div>
        )}
      </LiveList>
    </section>
  )
}
