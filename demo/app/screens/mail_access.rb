# What the Inbox's screens share: who is reading which inbox, and the writes
# both of them make. Every screen is opened with "member" and "inbox".
module MailAccess
  extend InstantRecord::RuntimeScoped

  def member = param("member")
  def inbox = param("inbox")

  # The params another screen is opened with, each a hash of strings.
  def place = { "member" => member, "inbox" => inbox }
  def place_in(name) = { "member" => member, "inbox" => name }
  def unread_place = { "member" => member, "inbox" => inbox, "filter" => "unread" }
  def thread_place(id) = { "member" => member, "inbox" => inbox, "thread" => id }

  def allowed? = MailDirectory.inboxes(member).include?(inbox)

  # A message of this inbox, or nil: one from another inbox is not found.
  def message(id)
    return nil unless allowed?
    MailEntry.find_by(id: id, mailbox_id: inbox, kind: "message")
  end

  # The ids of the open mail this member has not read, asked for once a
  # render and handed to whatever needs it.
  def unread_ids
    ids = {}
    MailEntry.open_messages.where(mailbox_id: inbox).where(MailEntry::UNREAD, member: member).each { |entry| ids[entry.id] = true }
    ids
  end

  # The same two halves as Email::MailboxesController: the server numbers the
  # entry itself, and the phone writes locally and lets sync carry it.
  server_only do
    def append(kind, parent)
      Mailbox.open_demo(inbox).append!(id: SecureRandom.uuid, author: member, attributes: { kind: kind, parent_id: parent })
    end

    def reply(parent, words)
      Mailbox.open_demo(inbox).append!(id: SecureRandom.uuid, author: member, attributes: { kind: "reply", parent_id: parent, body: words })
    end
  end

  browser_only do
    def append(kind, parent)
      MailEntry.create!(mailbox_id: inbox, author: member, kind: kind, parent_id: parent)
    end

    def reply(parent, words)
      MailEntry.create!(mailbox_id: inbox, author: member, kind: "reply", parent_id: parent, body: words)
    end
  end
end
