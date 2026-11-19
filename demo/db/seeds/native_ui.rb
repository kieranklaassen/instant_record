# A small fixed inbox for the iPhone app's simulator tests (native/ios/ui-test.sh):
# sixty messages in Support, so there is a page of older mail to load, one of
# them with a reply, and one message in Billing. Ids are fixed so a test can
# name the row it means.
MailEntry.delete_all
Mailbox.delete_all
support = Mailbox.create!(id: "support")
billing = Mailbox.create!(id: "billing")
started = Time.utc(2026, 11, 1, 9)

(1..60).each do |n|
  id = format("ui-%02d", n)
  entry = support.append!(id: id, author: "Rae #{n}", attributes: { kind: "message", address: "rae#{n}@example.test", subject: "Question #{n}", body: "Could you look at number #{n}?" })
  entry.update_columns(created_at: started + n.minutes)
end
support.append!(id: "ui-reply", author: "theo", attributes: { kind: "reply", parent_id: "ui-60", body: "Looking at it now." })
billing.append!(id: "ui-b1", author: "Sam", attributes: { kind: "message", address: "sam@example.test", subject: "October invoice", body: "Could you send a copy?" })
