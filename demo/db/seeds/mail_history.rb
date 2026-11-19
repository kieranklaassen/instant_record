# Backfill old Support conversations without replaying 10,000 live mutations.
# The newest imported row announces the backfill to clients already following this inbox.
module MailHistory
  COUNT = 10_000
  PROJECTS = %w[Atlas Beacon Cedar Drift Elm Finch Grove Harbor Iris Juniper].freeze
  SENDERS = ["Nora Bell", "Sam Ortiz", "June Park", "Eli Brooks", "Alex Chen", "Mina Lee"].freeze
  REQUESTS = [
    ["Invite a teammate", "Could you resend the invitation? Our new teammate starts Monday."],
    ["Delivery delay", "My colleague can see the conversation, but my browser is still catching up."],
    ["Move a conversation", "We filed this in the wrong mailbox. How should we move it?"],
    ["Export a transcript", "We need a copy of this conversation for the handover."],
    ["Change a notification", "Can we keep direct replies and mute the rest overnight?"],
    ["Restore a thread", "I archived a thread during triage. Can I find it again?"],
    ["Offline draft", "I wrote this on the train. When will my team see the reply?"]
  ].freeze

  def self.populate
    box = Mailbox.open_demo("support")
    box.with_lock do
      revision = box.revision + 1
      base = Time.utc(2024, 1, 1)
      inserted = 0
      (1..COUNT).each_slice(500) do |numbers|
        rows = numbers.map do |n|
          name = SENDERS[(n - 1) % SENDERS.size]
          project = PROJECTS[(n - 1) % PROJECTS.size]
          subject, body = REQUESTS[(n - 1) % REQUESTS.size]
          at = base + n.minutes
          { id: "history-support-#{n}", mailbox_id: box.id, kind: "message", author: name,
            address: "#{name.downcase.tr(' ', '.')}@example.test", subject: "#{subject} · #{project} ##{n}",
            body: "Hi Support,\n\n#{body}\n\n#{name}", created_at: at, updated_at: at,
            server_version: n == COUNT ? revision : -n, sync_state: "synced" }
        end
        inserted += MailEntry.insert_all(rows, unique_by: :id, returning: [:id]).rows.size
      end
      box.update!(revision: revision) if inserted.positive?
    end
  end
end
