// The controller sends a row as a list of strings (Email::MailboxesController
// #mail_row). This is the one place that names them.
export const mailRow = ([id, author, address, subject, body, at, unread, outside]) => ({
  id, author, address, subject, body, at, unread: unread === "1", outside: outside === "1",
})

export const replyRow = ([id, author, body, at]) => ({ id, author, body, at })

export const inboxPath = ({ member, inbox }, extra = {}) =>
  `/email?${new URLSearchParams({ member, inbox, ...extra })}`

export const initial = (name) => (name[0] || "?").toUpperCase()

// Internal teammates have a colour of their own; everyone else shares one.
export const avatarClass = (name) => `mail-avatar avatar-${name.toLowerCase().replace(/[^a-z]/g, "")}`

export function shortTime(at, now = new Date()) {
  const date = new Date(at)
  if (Number.isNaN(date.valueOf())) return ""
  return date.toDateString() === now.toDateString()
    ? date.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })
    : date.toLocaleDateString([], { month: "short", day: "numeric" })
}
