import { shortTime } from "../../lib/mail"
import Avatar from "../ui/Avatar"

// One message of a conversation. `pending` is a reply still on its way.
export default function Message({ author, detail, at, body, tinted, pending }) {
  return (
    <div className="mail-message" data-pending={String(!!pending)}>
      <div className="mail-byline">
        <Avatar name={author} tinted={tinted} />
        {detail ? <div><strong>{author}</strong><small>{detail}</small></div> : <strong>{author}</strong>}
        {pending ? <span className="mail-sending">Sending…</span> : <time dateTime={at}>{shortTime(at)}</time>}
      </div>
      <p>{body}</p>
    </div>
  )
}
