# One conversation. This screen is not drawn from stock elements: it hands
# its props to ConversationView, which the iPhone app wrote in SwiftUI
# (native/ios/Inbox), the way Email::MailboxesController hands the React page
# its props. Opened with `member`, `inbox` and `thread`. Archiving is the
# mailbox's action, so the view sends "archive" with the `thread` prop as its
# `id` back through `perform`.
class ThreadScreen < MailboxScreen
  def thread = param("thread")

  def body
    message = MailEntry.find_by(id: thread, mailbox_id: inbox, kind: "message") if allowed?
    unless message
      navigation(title: "") { text "This conversation is not in #{inbox.capitalize}.", tone: "secondary" }
      return
    end

    replies = MailEntry.where(mailbox_id: inbox, kind: "reply", parent_id: message.id).order(:created_at).to_a
    swift "ConversationView" do
      prop "thread", thread
      prop "subject", message.subject.to_s
      prop "participants", participants(message, replies)
      flag "archived", archived?(message)
      props "messages" do
        letter message.author, message.address.to_s, message.created_at.utc.iso8601(6), message.body.to_s
        replies.each do |reply|
          letter reply.author, "", reply.created_at.utc.iso8601(6), reply.body.to_s
        end
      end
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

  def participants(message, replies)
    names = [message.author]
    replies.each { |reply| names << reply.author unless names.include?(reply.author) }
    names.join(", ")
  end

  def archived?(message)
    MailEntry.exists?(mailbox_id: inbox, kind: "archive", parent_id: message.id)
  end
end
