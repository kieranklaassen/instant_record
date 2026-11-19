import { useEffect, useLayoutEffect, useRef, useState } from "react"
import Icon from "../ui/Icon"
import IconButton from "../ui/IconButton"
import Kbd from "../ui/Kbd"

// The reply to one conversation. Closed, it is one line that says who the
// reply goes to (or shows the draft waiting there). Open, it grows with what
// is written. The text is a draft from the first key: it survives moving to
// another conversation and back.
//
//   open     whether the box is open; the page opens it by key
//   drafts   from useDrafts
//   sender   a ref this fills with its send, so the page's keys can call it
//   onSend   (body, { archive }) sends
export default function ReplyBox({ id, address, open, keys, drafts, sender, onOpen, onClose, onSend }) {
  const [body, setBody] = useState(() => drafts.read(id))
  const field = useRef(null)

  useEffect(() => {
    if (!open) return
    const input = field.current
    input.focus()
    input.setSelectionRange(input.value.length, input.value.length)
  }, [open])

  // As tall as its text, up to the limit the stylesheet sets.
  useLayoutEffect(() => {
    const input = field.current
    if (!input) return
    input.style.height = "auto"
    input.style.height = `${input.scrollHeight}px`
  }, [body, open])

  const change = (text) => {
    setBody(text)
    drafts.save(id, text)
  }

  const send = ({ archive = false } = {}) => {
    const text = body.trim()
    if (!text) return
    change("")
    field.current?.blur()
    onSend(text, { archive })
  }

  useEffect(() => {
    if (!open) return
    sender.current = send
    return () => {
      if (sender.current === send) sender.current = null
    }
  })

  // Escape leaves the field. An empty reply closes with it; one with text
  // stays open, as a draft.
  const key = (event) => {
    if (event.key !== "Escape") return
    event.preventDefault()
    event.currentTarget.blur()
    if (!body.trim()) onClose()
  }

  if (!open) {
    return (
      <button type="button" className="mail-reply-prompt" data-draft={String(!!body)} onClick={onOpen}>
        <Icon name="reply" />
        <span>{body ? <><b>Draft</b> {body}</> : `Reply to ${address}`}</span>
        <Kbd chord={keys.reply} />
      </button>
    )
  }

  const empty = !body.trim()
  return (
    <form className="mail-reply" onSubmit={(event) => { event.preventDefault(); send() }}>
      <h3>Reply to {address}</h3>
      <textarea ref={field} aria-label="Reply" name="body" rows={2} placeholder="Write a reply…" maxLength={5000}
        value={body} onChange={(event) => change(event.target.value)} onKeyDown={key} />
      <div className="mail-reply-foot">
        <span>Saved on this device first, then sent</span>
        <div className="mail-reply-actions">
          <IconButton chord={keys.sendArchive} disabled={empty} onClick={() => send({ archive: true })}>Send and archive</IconButton>
          <IconButton quiet={false} className="mail-primary" tone="on-accent" chord={keys.send} disabled={empty} type="submit">Send</IconButton>
        </div>
      </div>
    </form>
  )
}
