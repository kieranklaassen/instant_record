# The Inbox on a phone: one member's open mail in one inbox, newest first.
# Opened with "member/inbox", such as "maya/support".
class MailboxScreen < InstantRecord::Native::Screen
  extend InstantRecord::RuntimeScoped

  def member = arg.split("/")[0].to_s
  def inbox = arg.split("/")[1].to_s

  def body
    navigation title: inbox.capitalize do
      list do
        unread = unread_ids
        messages.each do |entry|
          thread = "#{member}/#{inbox}/#{entry.id}"
          row id: entry.id, link: "thread", arg: thread, action: "read" do
            stack "horizontal" do
              image "circle.fill", tone: "accent" if unread.key?(entry.id)
              text entry.author, style: "headline"
              date entry.created_at.utc.iso8601(6), style: "caption", tone: "secondary"
            end
            text entry.subject.to_s
            text entry.body.to_s, style: "subheadline", tone: "secondary"
            swipe "Archive", action: "archive", arg: thread, role: "destructive", image: "archivebox"
          end
        end
      end
    end
  end

  # Both actions name a message as "member/inbox/id".
  def perform(action, arg)
    parts = arg.split("/")
    return unless allowed? && parts.size == 3 && parts[0] == member && parts[1] == inbox
    message = MailEntry.find_by(id: parts[2], mailbox_id: inbox, kind: "message")
    return unless message

    case action
    when "read" then append("read", message.id) if unread_ids.key?(message.id)
    when "archive" then append("archive", message.id)
    end
  end

  private

  def allowed? = MailDirectory.inboxes(member).include?(inbox)

  def messages
    return [] unless allowed?
    MailEntry.open_messages.where(mailbox_id: inbox).order(created_at: :desc, id: :desc).limit(MailEntry::PAGE_SIZE).to_a
  end

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
  end

  browser_only do
    def append(kind, parent)
      MailEntry.create!(mailbox_id: inbox, author: member, kind: kind, parent_id: parent)
    end
  end
end
