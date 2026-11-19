# The inbox compiled/test/offline-inbox.mjs expects: 600 open conversations in
# Support, the oldest of them the only one that mentions a zebra, and a shell
# already built. Run with bin/rails runner against the sync server's database.
MailEntry.where(mailbox_id: "support").delete_all
Mailbox.where(id: "support").delete_all
box = Mailbox.create!(id: "support")
600.times do |number|
  subject = number.zero? ? "A zebra at the door" : "Request #{number}"
  message = box.append!(id: SecureRandom.uuid, author: "Rae #{number}",
    attributes: { kind: "message", address: "rae#{number}@example.test", subject: subject, body: "Can you help with number #{number}?" })
  box.append!(id: SecureRandom.uuid, author: "theo", attributes: { kind: "reply", parent_id: message.id, body: "On it." }) if (number % 5).zero?
end
shell = MailShell.build(box)
puts "support: #{box.reload.revision} entries, shell at #{shell.cursor} (#{shell.bytes} bytes)"
