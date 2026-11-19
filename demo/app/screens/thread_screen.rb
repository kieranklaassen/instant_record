# One conversation. This screen is not drawn from stock elements: it hands
# its props to ConversationView, which the iPhone app wrote in SwiftUI
# (native/ios/Inbox), the way Email::MailboxesController hands the React page
# its props. Under it sits a reply box drawn from Ruby. Opened with `member`,
# `inbox` and `thread`. Opening it marks the message read.
class ThreadScreen < InstantRecord::Native::Screen
  include MailAccess

  def body
    entry = message(param("thread"))
    if entry.nil?
      navigation(title: "") { text "This conversation is not in #{inbox.capitalize}.", tone: "secondary" }
      return
    end

    replies = MailEntry.where(mailbox_id: inbox, kind: "reply", parent_id: entry.id).order(:created_at).to_a
    swift "ConversationView" do
      prop "subject", entry.subject.to_s
      prop "participants", participants(entry, replies)
      flag "archived", archived?(entry)
      props "messages" do
        letter entry.author, entry.address.to_s, entry.created_at.utc.iso8601(6), entry.body.to_s
        replies.each do |reply|
          letter reply.author, "", reply.created_at.utc.iso8601(6), reply.body.to_s
        end
      end
    end
    bottom do
      field "body", label: "Reply", multiline: true
      button "Send", action: "reply", image: "send"
    end
  end

  # "open" arrives when the screen is opened over the mailbox. "reply"
  # carries what was typed as `body`. "archive" comes from the Swift view's
  # own button.
  def perform(action, args, values)
    entry = message(param("thread"))
    return if entry.nil?

    case action
    when "open" then append("read", entry.id) if unread_ids.key?(entry.id)
    when "archive" then append("archive", entry.id)
    when "reply"
      words = values.fetch("body", "").strip
      reply(entry.id, words) unless words.empty?
    end
  end

  private

  def letter(author, address, written, words)
    record do
      prop "author", author
      prop "address", address
      time "date", written
      prop "body", words
      flag "mine", author == member
    end
  end

  def participants(entry, replies)
    names = [entry.author]
    replies.each { |reply| names << reply.author unless names.include?(reply.author) }
    names.join(", ")
  end

  def archived?(entry)
    MailEntry.exists?(mailbox_id: inbox, kind: "archive", parent_id: entry.id)
  end
end
