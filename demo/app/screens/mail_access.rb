# What the Inbox's screens share: one member reading one inbox, and the
# writes both screens make. A screen makes one from its "member" and "inbox"
# params and asks it, so neither screen inherits from the other.
class MailAccess
  extend InstantRecord::RuntimeScoped

  attr_reader :member, :inbox

  def initialize(member, inbox)
    @member = member
    @inbox = inbox
  end

  def allowed? = MailDirectory.inboxes(@member).include?(@inbox)

  # A message of this inbox, or nil: one from another inbox is not found.
  def message(id)
    return nil unless allowed?
    MailEntry.find_by(id: id, mailbox_id: @inbox, kind: "message")
  end

  # The ids of the open mail this member has not read. A screen asks once a
  # render and hands the answer to whatever needs it.
  def unread_ids
    ids = {}
    MailEntry.open_messages.where(mailbox_id: @inbox).where(MailEntry::UNREAD, member: @member).each { |entry| ids[entry.id] = true }
    ids
  end

  # The same two halves as Email::MailboxesController: the server numbers the
  # entry itself, and the phone writes locally and lets sync carry it.
  server_only do
    def append(kind, parent)
      Mailbox.open_demo(@inbox).append!(id: SecureRandom.uuid, author: @member, attributes: { kind: kind, parent_id: parent })
    end

    def reply(parent, words)
      Mailbox.open_demo(@inbox).append!(id: SecureRandom.uuid, author: @member, attributes: { kind: "reply", parent_id: parent, body: words })
    end
  end

  browser_only do
    def append(kind, parent)
      MailEntry.create!(mailbox_id: @inbox, author: @member, kind: kind, parent_id: parent)
    end

    def reply(parent, words)
      MailEntry.create!(mailbox_id: @inbox, author: @member, kind: "reply", parent_id: parent, body: words)
    end
  end
end
