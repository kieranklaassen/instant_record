# The Inbox on a phone: one member's open mail in one inbox, newest first.
# Opened with `member` and `inbox`, and with `filter: "unread"` to list only
# what the member has not read.
class MailboxScreen < InstantRecord::Native::Screen
  extend InstantRecord::RuntimeScoped

  def member = param("member")
  def inbox = param("inbox")
  def mail = MailAccess.new(member, inbox)
  def unread_only? = param("filter") == "unread"

  def body
    unread = mail.unread_ids
    shown = messages
    waiting = shown.count { |entry| unread.key?(entry.id) }
    older = older?
    navigation title: inbox.capitalize do
      list refreshable: true do
        # One view among the rows that the app wrote in SwiftUI. The unread
        # figure counts what is on the phone, so it is a floor ("12+") while
        # older mail is still on the server.
        swift "InboxSummary" do
          prop "inbox", inbox.capitalize
          number "unread", unread.size
          number "showing", shown.size
          flag "filtered", unread_only?
          flag "more", older
        end
        shown.each do |entry|
          row id: entry.id, link: "thread", params: thread_place(entry.id.to_s) do
            stack "horizontal" do
              image "unread", tone: "accent" if unread.key?(entry.id)
              text entry.author, style: "headline", lines: 1
              spacer
              date entry.created_at.utc.iso8601(6), style: "caption", tone: "secondary"
            end
            text entry.subject.to_s, lines: 1
            text entry.body.to_s, style: "subheadline", tone: "secondary", lines: 2
            swipe "Archive", action: "archive", args: { "id" => entry.id.to_s }, role: "destructive", image: "archive"
          end
        end
        text(unread_only? ? "You're all caught up" : "No mail", tone: "secondary") if shown.empty?
        more "older:#{inbox}", query: below(shown.last) if older && !shown.empty?
      end
      toolbar do
        button "Inboxes", image: "person", position: "leading" do
          MailDirectory.inboxes(member).each do |name|
            item name.capitalize, replace: "mailbox", params: place_in("#{name}"), image: "inbox", selected: name == inbox
          end
        end
        button "View", image: "filter", position: "trailing" do
          item "All", replace: "mailbox", params: place, selected: !unread_only?
          item "Unread", replace: "mailbox", params: unread_place, selected: unread_only?
          item "Mark #{waiting} as read", action: "read_all", image: "read" if waiting > 0
          item "Send feedback", sheet: "feedback", params: place, image: "compose"
        end
      end
    end
  end

  # "archive" names a message of this inbox by its `id`. "read_all" marks the
  # listed mail read.
  def perform(action, args, values)
    mail = self.mail
    return unless mail.allowed?

    case action
    when "read_all" then read_all
    when "archive"
      entry = mail.message(args.fetch("id", ""))
      mail.append("archive", entry.id) if entry
    end
  end

  private

  # Where this screen is, and the places a link from here leads: the params
  # another screen is opened with, each a hash of strings.
  def place = { "member" => member, "inbox" => inbox }
  def place_in(name) = { "member" => member, "inbox" => name }
  def unread_place = { "member" => member, "inbox" => inbox, "filter" => "unread" }
  def thread_place(id) = { "member" => member, "inbox" => inbox, "thread" => id }

  def messages
    return [] unless mail.allowed?
    open = MailEntry.open_messages.where(mailbox_id: inbox)
    open = open.where(MailEntry::UNREAD, member: member) if unread_only?
    held(open.order(created_at: :desc, id: :desc)).to_a
  end

  def read_all
    mail = self.mail
    unread = mail.unread_ids
    messages.each { |entry| mail.append("read", entry.id) if unread.key?(entry.id) }
  end

  # What the app asks the sync address's records door for: the page of mail
  # below this message.
  def below(entry)
    "type=MailEntry&before_created_at=" + entry.created_at.utc.iso8601(6) + "&before_id=" + entry.id.to_s
  end

  # The server holds the whole inbox and shows its first page, as the web
  # Inbox's first render does. The phone holds the pages it has loaded and
  # shows all of them.
  server_only do
    def held(scope) = scope.limit(MailEntry::PAGE_SIZE)
    def older? = false
  end

  client_only do
    def held(scope) = scope

    # What the last page of older mail said, or before any was asked for,
    # whether the first page came full.
    def older?
      return false unless mail.allowed?
      mark = InstantRecord::SyncMetadata.get("history:older:" + inbox)
      return mark == "more" unless mark.nil?
      MailEntry.open_messages.where(mailbox_id: inbox).count >= MailEntry::PAGE_SIZE
    end
  end
end
