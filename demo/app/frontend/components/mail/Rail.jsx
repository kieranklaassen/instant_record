import { capitalize, inboxPath } from "../../lib/mail"
import Avatar from "../ui/Avatar"
import Icon from "../ui/Icon"
import Kbd from "../ui/Kbd"

// The left rail: compose, the mailboxes, and who to view the demo as.
export default function Rail({ member, inbox, inboxes, people, composeKey, helpKey, onCompose, onHelp }) {
  return (
    <aside className="mail-rail">
      <div className="mail-brand">
        <span className="mail-mark" aria-hidden="true"><Icon name="mail" size={15} /></span>
        Inbox
      </div>
      <button type="button" className="mail-primary mail-compose-link" onClick={onCompose}>
        <Icon name="compose" /> Compose <Kbd chord={composeKey} tone="on-accent" silent />
      </button>
      <div className="mail-rail-section">Mailboxes</div>
      <nav aria-label="Mailboxes" className="mail-folders">
        {inboxes.map((box) => (
          <a key={box} href={inboxPath({ member, inbox: box })} aria-current={String(box === inbox)}>
            <span className="mail-folder-icon"><Icon name="inbox" size={17} /></span>
            {capitalize(box)}
          </a>
        ))}
      </nav>
      <div className="mail-team">
        <div className="mail-rail-section">View as</div>
        <nav aria-label="Demo teammate">
          {people.map(([person, box]) => (
            <a key={person} href={inboxPath({ member: person, inbox: box })} aria-current={String(person === member)}>
              <Avatar name={person} size="small" />
              {capitalize(person)}
            </a>
          ))}
        </nav>
      </div>
      <button type="button" className="mail-keys-hint" onClick={onHelp}><Kbd chord={helpKey} silent /> Keyboard shortcuts</button>
    </aside>
  )
}
