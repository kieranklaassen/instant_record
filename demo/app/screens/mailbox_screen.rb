# The Inbox on a phone: one member's open mail in one inbox, newest first.
# Opened with "member" and "inbox", such as maya and support, and with
# "show" as "unread" to list only what the member has not read.
class MailboxScreen < InstantRecord::Native::Screen
  include MailAccess
  extend InstantRecord::RuntimeScoped

  def unread_only? = param("show") == "unread"

  def body
    unread = unread_ids
    shown = messages
    waiting = shown.count { |entry| unread.key?(entry.id) }
    more = more_on_server?
    navigation title: inbox.capitalize do
      list refreshable: true do
        swift "InboxSummary" do
          prop "inbox", inbox.capitalize
          number "unread", unread.size
          number "showing", shown.size
          flag "filtered", unread_only?
          flag "more", more
        end
        shown.each do |entry|
          row id: entry.id, link: "thread", with: at(entry.id) do
            stack "horizontal" do
              image "unread", tone: "accent" if unread.key?(entry.id)
              text entry.author, style: "headline", lines: 1
              spacer
              date entry.created_at.utc.iso8601(6), style: "caption", tone: "secondary"
            end
            text entry.subject, lines: 1
            text entry.body, style: "subheadline", tone: "secondary", lines: 2
            swipe "Archive", action: "archive", with: { "id" => entry.id.to_s }, role: "destructive", image: "archive"
          end
        end
        button "Load older mail", action: "older" if more
      end
      toolbar do
        button "Inboxes", image: "person", position: "leading" do
          MailDirectory.inboxes(member).each do |name|
            item name.capitalize, link: "mailbox", with: { "member" => member, "inbox" => name.to_s }, image: "inbox", selected: name == inbox
          end
        end
        button "View", image: "filter", position: "trailing" do
          item "All", link: "mailbox", with: here, selected: !unread_only?
          item "Unread", link: "mailbox", with: { "member" => member, "inbox" => inbox, "show" => "unread" }, selected: unread_only?
          item "Mark #{waiting} read", action: "read_all", image: "read" if waiting > 0
        end
      end
    end
  end

  # "archive" names a message by "id". "read_all" marks the listed mail read,
  # and "older" loads the page of mail below what the phone holds.
  def perform(action, params)
    return unless allowed?

    case action
    when "read_all" then read_all
    when "older" then older
    when "archive"
      entry = message(params["id"].to_s)
      append("archive", entry.id) if entry
    end
  end

  private

  def messages
    return [] unless allowed?
    open = MailEntry.open_messages.where(mailbox_id: inbox)
    open = open.where(MailEntry::UNREAD, member: member) if unread_only?
    held(open.order(created_at: :desc, id: :desc)).to_a
  end

  def read_all
    unread = unread_ids
    messages.each { |entry| append("read", entry.id) if unread.key?(entry.id) }
  end

  # The server holds the whole inbox and shows its first page. The phone
  # holds the pages it has loaded and shows all of them.
  server_only do
    def held(scope) = scope.limit(MailEntry::PAGE_SIZE)

    def more_on_server?
      allowed? && MailEntry.open_messages.where(mailbox_id: inbox).count > MailEntry::PAGE_SIZE
    end

    def older
    end
  end

  browser_only do
    def held(scope) = scope

    # What the last page the server sent said, kept in the database so it
    # holds across redraws. Before any page: a full first page means more.
    # Archived messages count, or archiving one would hide the older mail.
    def more_on_server?
      mark = InstantRecord::SyncMetadata.get("older:" + inbox)
      return mark == "more" unless mark.nil?
      MailEntry.where(mailbox_id: inbox, kind: "message").count >= MailEntry::PAGE_SIZE
    end

    # The page below the oldest message here, and whether more lies under
    # it, stored together. With no network nothing changes.
    def older
      last = MailEntry.open_messages.where(mailbox_id: inbox).order(created_at: :asc, id: :asc).first
      return if last.nil?
      page = InstantRecord::Client.transport.get_json("/records?type=MailEntry&before_created_at=" + last.created_at.utc.iso8601(6) + "&before_id=" + last.id)
      records = Array(page["records"])
      InstantRecord::OutboxMutation.transaction do
        records.each { |record| InstantRecord::Client.apply_change(record) }
        InstantRecord::SyncMetadata.set("older:" + inbox, page["has_more"] == true ? "more" : "end")
      end
    rescue InstantRecord::Client::Transport::Error
      nil
    end
  end
end
