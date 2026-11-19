// The controller sends a row as a list of strings (Email::MailboxesController
// #mail_row). This is the one place that names them.
export const mailRow = ([id, author, address, subject, body, at, unread, outside]) => ({
  id, author, address, subject, body, at, unread: unread === "1", outside: outside === "1",
})

export const replyRow = ([id, author, body, at]) => ({ id, author, body, at })

export const inboxPath = ({ member, inbox }, extra = {}) =>
  `/email?${new URLSearchParams({ member, inbox, ...extra })}`

export const capitalize = (word) => word[0].toUpperCase() + word.slice(1)

export function shortTime(at, now = new Date()) {
  const date = new Date(at)
  if (Number.isNaN(date.valueOf())) return ""
  return date.toDateString() === now.toDateString()
    ? date.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })
    : date.toLocaleDateString([], { month: "short", day: "numeric" })
}

// What the list shows while writes are on their way: rows whose archive is
// held are left out, and a row with a mark not yet answered wears the mark.
// The unread count follows both.
//
//   held   ids to leave out (useUndoable)
//   marks  id => { unread } for marks on their way (useMailActions)
export function withOverlay(rows, unreadCount, { held, marks }) {
  if (!held.size && !marks.size) return { rows, unreadCount }
  let count = unreadCount
  const shown = []
  for (const row of rows) {
    const unread = marks.has(row.id) ? marks.get(row.id).unread : row.unread
    if (unread !== row.unread) count += unread ? 1 : -1
    if (held.has(row.id)) {
      if (unread) count -= 1
      continue
    }
    shown.push(unread === row.unread ? row : { ...row, unread })
  }
  return { rows: shown, unreadCount: Math.max(count, 0) }
}

// The first of `ids`, in list order, that is in `among`. Focus goes there
// before a block of rows leaves, so it lands on the row that takes the
// block's place.
export const firstOf = (ids, among) => ids.find((id) => among.has(id)) ?? null

export const archivedLabel = (count) =>
  count === 1 ? "Conversation archived" : `${count} conversations archived`

const sameReply = (reply, entry) => reply.author === entry.author && reply.body === entry.body

// How many replies like this one a thread already holds, noted when a reply
// is sent so its arrival can be told from an older one that reads the same.
export const seenBefore = (replies, entry) => replies.filter((reply) => sameReply(reply, entry)).length

// A thread's replies with the ones still on their way after them. A reply on
// its way is dropped once the thread holds one more like it than it did.
export function withPending(replies, pending) {
  const claimed = new Map()
  const waiting = pending.filter((entry) => {
    const key = `${entry.author}\n${entry.body}`
    const used = claimed.get(key) || 0
    const arrived = seenBefore(replies, entry) - entry.seen - used > 0
    if (arrived) claimed.set(key, used + 1)
    return !arrived
  })
  return [...replies, ...waiting.map((entry) => ({ id: entry.key, author: entry.author, body: entry.body, at: entry.at, pending: true }))]
}

// Where a draft is kept. `id` is a conversation, or "compose".
export const draftKey = ({ member, inbox }, id) => `inbox-draft:${member}:${inbox}:${id}`
