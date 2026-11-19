# The Inbox on a phone: one member's open mail in one inbox, newest first.
# Opened with `member` and `inbox`, and with `filter: "unread"` to list only
# what the member has not read.
class MailboxScreen < InstantRecord::Native::Screen
  extend InstantRecord::RuntimeScoped

  def member = param("member")
  def inbox = param("inbox")
  def unread_only? = param("filter") == "unread"

  def body
    navigation title: inbox.capitalize do
      list refreshable: true do
        unread = unread_ids
        shown = messages
        # One view among the rows that the app wrote in SwiftUI.
        swift "InboxSummary" do
          prop "inbox", inbox.capitalize
          number "unread", unread.size
          number "showing", shown.size
          prop "filter", unread_only? ? "unread" : "all"
        end
        shown.each do |entry|
          message = { "id" => entry.id.to_s }
          row id: entry.id, link: "thread", params: place.merge("thread" => entry.id.to_s), action: "read", args: message do
            stack "horizontal" do
              image "circle.fill", tone: "accent" if unread.key?(entry.id)
              text entry.author, style: "headline"
              date entry.created_at.utc.iso8601(6), style: "caption", tone: "secondary"
            end
            text entry.subject.to_s
            text entry.body.to_s, style: "subheadline", tone: "secondary"
            swipe "Archive", action: "archive", args: message, role: "destructive", image: "archivebox"
          end
        end
      end
      toolbar do
        button "Inboxes", image: "person.crop.circle", position: "leading" do
          MailDirectory.inboxes(member).each do |name|
            item name.capitalize, link: "mailbox", params: { "member" => member, "inbox" => name }, image: "tray", selected: name == inbox
          end
        end
        button "View", image: "slider.horizontal.3", position: "trailing" do
          item "All", link: "mailbox", params: place, selected: !unread_only?
          item "Unread", link: "mailbox", params: place.merge("filter" => "unread"), selected: unread_only?
          item "Mark all read", action: "read_all", image: "envelope.open"
        end
      end
    end
  end

  # "read" and "archive" name a message of this inbox by its `id`.
  # "read_all" marks the listed mail read.
  def perform(action, args, values)
    return unless allowed?
    return read_all if action == "read_all"
    message = MailEntry.find_by(id: args.fetch("id", ""), mailbox_id: inbox, kind: "message")
    return unless message

    case action
    when "read" then append("read", message.id) if unread_ids.key?(message.id)
    when "archive" then append("archive", message.id)
    end
  end

  private

  # Where this screen is: what a link to the same inbox starts from.
  def place = { "member" => member, "inbox" => inbox }

  def allowed? = MailDirectory.inboxes(member).include?(inbox)

  def messages
    return [] unless allowed?
    open = MailEntry.open_messages.where(mailbox_id: inbox)
    open = open.where(MailEntry::UNREAD, member: member) if unread_only?
    open.order(created_at: :desc, id: :desc).limit(MailEntry::PAGE_SIZE).to_a
  end

  def read_all
    unread = unread_ids
    messages.each { |entry| append("read", entry.id) if unread.key?(entry.id) }
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
