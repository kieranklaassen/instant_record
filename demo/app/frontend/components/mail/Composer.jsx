import { useForm } from "@inertiajs/react"
import { useEffect } from "react"
import Icon from "../ui/Icon"
import IconButton from "../ui/IconButton"

const WRITE = { preserveState: true, preserveScroll: true, async: true }
const EMPTY = { address: "", subject: "", body: "" }
const DRAFT = "compose"

const kept = (drafts) => {
  try {
    return { ...EMPTY, ...JSON.parse(drafts.read(DRAFT) || "{}") }
  } catch {
    return EMPTY
  }
}

// A new conversation. A write is an Inertia form post: Rails redirects back
// and the answer carries the fresh props. What is typed is kept as a draft
// until it is sent.
//
//   sender   a ref this fills with its send, so the page's keys can call it
export default function Composer({ scope, drafts, sender, keys, onSend, onSent, onFail, onClose }) {
  const form = useForm(() => kept(drafts))

  const field = (name) => ({
    name,
    value: form.data[name],
    onChange: (event) => {
      form.setData(name, event.target.value)
      drafts.save(DRAFT, JSON.stringify({ ...form.data, [name]: event.target.value }))
    },
  })

  const ready = form.data.address.trim() && form.data.subject.trim() && form.data.body.trim()

  const send = () => {
    if (!ready || form.processing) return
    form.transform((data) => ({ ...scope, kind: "message", address: data.address.trim(), subject: data.subject.trim(), body: data.body.trim() }))
    onSend()
    form.post("/email", {
      ...WRITE,
      onSuccess: () => {
        drafts.clear(DRAFT)
        onSent()
      },
      onHttpException: onFail,
      onNetworkError: onFail,
    })
  }

  useEffect(() => {
    sender.current = send
    return () => {
      if (sender.current === send) sender.current = null
    }
  })

  return (
    <div className="mail-reader-scroll">
      <div className="mail-compose-head">
        <h2>New conversation</h2>
        <button type="button" className="mail-compose-close" aria-label="Close composer" onClick={onClose}><Icon name="close" size={18} /></button>
      </div>
      <form className="mail-compose" onSubmit={(event) => { event.preventDefault(); send() }}>
        <label>To<input type="email" placeholder="person@example.test" maxLength={254} required autoFocus {...field("address")} /></label>
        <label>Subject<input placeholder="Subject" maxLength={180} required {...field("subject")} /></label>
        <label className="mail-body-field">Message
          <textarea placeholder="Write your message…" maxLength={5000} required {...field("body")} />
        </label>
        <IconButton quiet={false} className="mail-primary" tone="on-accent" chord={keys.send} disabled={form.processing} type="submit">Send message</IconButton>
      </form>
    </div>
  )
}
