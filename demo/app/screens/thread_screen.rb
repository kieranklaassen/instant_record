# One conversation: the message, its replies, and a way to archive it.
# Opened with "member/inbox/id". Archiving is the mailbox's action, so the
# button hands the same argument to MailboxScreen through `perform`.
class ThreadScreen < MailboxScreen
  def thread = arg.split("/")[2].to_s

  def body
    message = MailEntry.find_by(id: thread, mailbox_id: inbox, kind: "message") if allowed?
    unless message
      navigation(title: "") { text "This conversation is not in #{inbox.capitalize}.", tone: "secondary" }
      return
    end

    navigation title: message.subject.to_s do
      list do
        section do
          letter message.author, message.address.to_s, message.created_at.utc.iso8601(6), message.body.to_s
        end
        MailEntry.where(mailbox_id: inbox, kind: "reply", parent_id: message.id).order(:created_at).each do |reply|
          section do
            letter reply.author, "", reply.created_at.utc.iso8601(6), reply.body.to_s
          end
        end
      end
      toolbar do
        button "Archive", action: "archive", arg: arg, role: "destructive", image: "archivebox" unless archived?(message)
      end
    end
  end

  private

  def letter(author, address, written, words)
    row do
      stack "horizontal" do
        text author, style: "headline"
        date written, style: "caption", tone: "secondary"
      end
      text address, style: "caption", tone: "secondary" unless address.empty?
      text words
    end
  end

  def archived?(message)
    MailEntry.exists?(mailbox_id: inbox, kind: "archive", parent_id: message.id)
  end
end
