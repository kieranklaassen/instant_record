import { useForm } from "@inertiajs/react"
import { useEffect, useRef } from "react"
import { avatarClass, initial, shortTime } from "../lib/mail"

const sendOnCommandEnter = (event) => {
  if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) event.currentTarget.form.requestSubmit()
}

function Message({ author, detail, at, body, coloured }) {
  return (
    <div className="mail-message">
      <div className="mail-byline">
        <span className={coloured ? avatarClass(author) : "mail-avatar"}>{initial(author)}</span>
        {detail ? <div><strong>{author}</strong><small>{detail}</small></div> : <strong>{author}</strong>}
        <time dateTime={at}>{shortTime(at)}</time>
      </div>
      <p>{body}</p>
    </div>
  )
}

// A write is an Inertia form post. Rails redirects back, and the answer
// carries the fresh props.
const WRITE = { preserveState: true, preserveScroll: true, async: true }

export function Thread({ scope, message, replies, replyFocus, onMark, onArchive }) {
  const form = useForm({ body: "" })
  const field = useRef(null)

  // A new conversation starts with an empty reply.
  useEffect(() => form.reset(), [message.id])
  useEffect(() => {
    if (replyFocus) field.current?.focus()
  }, [replyFocus])

  const submit = (event) => {
    event.preventDefault()
    if (!form.data.body.trim()) return
    form.transform((data) => ({ ...scope, kind: "reply", parent_id: message.id, body: data.body.trim() }))
    form.post("/email", { ...WRITE, onSuccess: () => form.reset() })
  }

  const count = replies.length + 1
  return (
    <>
      <article className="mail-thread">
        <header className="mail-thread-tools">
          <span>{count} {count === 1 ? "message" : "messages"}</span>
          <div className="mail-thread-actions">
            <button type="button" onClick={() => onMark(message.unread ? "read" : "unread")}>
              {message.unread ? "Mark read" : "Mark unread"}
            </button>
            <button type="button" aria-label="Archive conversation" onClick={onArchive}>Archive</button>
          </div>
        </header>
        <h2>{message.subject}</h2>
        <Message author={message.author} detail={`${message.outside ? "From" : "To"} ${message.address}`}
          at={message.at} body={message.body} />
        <div className="mail-replies">
          {replies.map((reply) => (
            <Message key={reply.id} author={reply.author} at={reply.at} body={reply.body} coloured />
          ))}
        </div>
      </article>
      <form className="mail-reply" onSubmit={submit}>
        <h3>Reply to {message.address}</h3>
        <textarea ref={field} aria-label="Reply" name="body" placeholder="Write a reply…" maxLength={5000} required
          value={form.data.body} onChange={(event) => form.setData("body", event.target.value)} onKeyDown={sendOnCommandEnter} />
        <div className="mail-reply-foot">
          <span>Saved on this device first, then sent</span>
          <button className="mail-primary" disabled={form.processing}>Send reply</button>
        </div>
      </form>
    </>
  )
}

export function Composer({ scope, onSend, onSent, onClose }) {
  const form = useForm({ address: "", subject: "", body: "" })
  const field = (name) => ({ name, value: form.data[name], onChange: (event) => form.setData(name, event.target.value) })

  const submit = (event) => {
    event.preventDefault()
    form.transform((data) => ({ ...scope, kind: "message", address: data.address.trim(), subject: data.subject.trim(), body: data.body.trim() }))
    onSend()
    form.post("/email", { ...WRITE, onSuccess: onSent })
  }

  return (
    <>
      <div className="mail-compose-head">
        <h2>New conversation</h2>
        <button type="button" className="mail-compose-close" aria-label="Close composer" onClick={onClose}>×</button>
      </div>
      <form className="mail-compose" onSubmit={submit}>
        <label>To<input type="email" placeholder="person@example.test" maxLength={254} required autoFocus {...field("address")} /></label>
        <label>Subject<input placeholder="Subject" maxLength={180} required {...field("subject")} /></label>
        <label className="mail-body-field">Message
          <textarea placeholder="Write your message…" maxLength={5000} required onKeyDown={sendOnCommandEnter} {...field("body")} />
        </label>
        <button className="mail-primary" disabled={form.processing}>Send message</button>
      </form>
    </>
  )
}

export function Clear() {
  return (
    <div className="mail-empty">
      <span className="mail-mark" aria-hidden="true">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="m5 12 4 4L19 6" /></svg>
      </span>
      <h2>Your inbox is clear</h2>
      <p>Generate an incoming email to start a conversation.</p>
    </div>
  )
}

const KEYS = [
  ["j", "k", "Next and previous conversation"],
  ["Enter", "o", "Open"],
  ["Esc", "u", "Back to the list"],
  ["e", null, "Archive"],
  ["r", null, "Reply"],
  ["c", null, "Compose"],
  ["?", null, "Show or hide this list"],
]

export function KeyList({ onClose }) {
  return (
    <div className="mail-keys" role="dialog" aria-label="Keyboard shortcuts" onClick={onClose}>
      <div className="mail-keys-card" onClick={(event) => event.stopPropagation()}>
        <h2>Keys</h2>
        <dl>
          {KEYS.map(([first, second, does]) => (
            <div key={first}>
              <dt><kbd>{first}</kbd>{second && <> <span>or</span> <kbd>{second}</kbd></>}</dt>
              <dd>{does}</dd>
            </div>
          ))}
        </dl>
      </div>
    </div>
  )
}
