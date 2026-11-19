import { useEffect, useLayoutEffect, useRef, useState } from "react"
import IconButton from "../ui/IconButton"
import Message from "./Message"

// The open conversation. It starts at the top when the conversation changes
// and otherwise keeps its place: a reply arriving over sync does not move it,
// and a reply sent from here is brought into view.
//
//   scroller  a ref the page reads, to scroll the conversation by key
export default function Thread({ message, replies, keys, scroller, onReply, onUnread, onArchive }) {
  const [scrolled, setScrolled] = useState(false)
  const sending = replies.filter((reply) => reply.pending).length
  const before = useRef(sending)

  useLayoutEffect(() => {
    scroller.current.scrollTop = 0
    setScrolled(false)
  }, [message.id, scroller])

  useEffect(() => {
    if (sending > before.current) scroller.current.scrollTo({ top: scroller.current.scrollHeight, behavior: "smooth" })
    before.current = sending
  }, [sending, scroller])

  const count = replies.length + 1
  return (
    <div className="mail-reader-scroll" ref={scroller} tabIndex={-1} onScroll={(event) => setScrolled(event.currentTarget.scrollTop > 4)}>
      <header className="mail-thread-tools" data-scrolled={String(scrolled)}>
        <span>{count} {count === 1 ? "message" : "messages"}</span>
        <div className="mail-thread-actions">
          <IconButton icon="reply" chord={keys.reply} onClick={onReply}>Reply</IconButton>
          <IconButton icon="unread" chord={keys.unread} onClick={onUnread}>Mark unread</IconButton>
          <IconButton icon="archive" chord={keys.archive} aria-label="Archive conversation" onClick={onArchive}>Archive</IconButton>
        </div>
      </header>
      <article className="mail-thread">
        <h2>{message.subject}</h2>
        <Message author={message.author} detail={`${message.outside ? "From" : "To"} ${message.address}`}
          at={message.at} body={message.body} tinted={false} />
        <div className="mail-replies">
          {replies.map((reply) => (
            <Message key={reply.id} author={reply.author} at={reply.at} body={reply.body} pending={reply.pending} />
          ))}
        </div>
      </article>
    </div>
  )
}
