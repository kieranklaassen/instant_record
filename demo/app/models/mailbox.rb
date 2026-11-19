class Mailbox < ApplicationRecord
  has_many :mail_entries

  WELCOME = {
    "support" => ["Rae", "rae@example.test", "Can we invite our night shift?", "We share a Support inbox across shifts. How can I invite the evening team?"],
    "billing" => ["Sam", "sam@example.test", "A copy of the October invoice", "Could you send over the October invoice before Friday?"]
  }.freeze

  INCOMING = {
    "support" => [
      ["Nora Bell", "nora", "Moving our team into one inbox", "Hi there, we’re bringing two teams together next week. Can we keep our existing conversations when we move?"],
      ["Alex Chen", "alex", "A quick question about invitations", "I just invited a colleague and noticed a typo in their address. What’s the easiest way to resend the invite?"],
      ["June Park", "june", "Thanks for the walkthrough", "The shared inbox is working beautifully for our studio. Thanks for helping us get set up yesterday!"]
    ],
    "billing" => [
      ["Lena Ortiz", "lena", "Updating our billing contact", "Could you put our finance team on the next invoice? Happy to send the details over."],
      ["Eli Brooks", "eli", "Receipt for our annual plan", "We renewed last week. Could you send a copy of the receipt for our records?"],
      ["Mina Lee", "mina", "Adding two more seats", "We have two people joining on Monday. How will the extra seats show up on our next bill?"]
    ]
  }.freeze

  def generate_incoming!
    examples = INCOMING.fetch(id)
    recent = mail_entries.where(subject: examples.map(&:third)).order(server_version: :desc).limit(examples.size - 1).pluck(:subject)
    sender, handle, subject, body = examples.reject { |example| recent.include?(example.third) }.sample
    append!(id: SecureRandom.uuid, author: sender, attributes: {
      kind: "message", address: "#{handle}@example.test", subject: subject, body: body
    })
  end

  def self.open_demo(name)
    find_by(id: name) || transaction do
      author, address, subject, body = WELCOME.fetch(name)
      mailbox = create_or_find_by!(id: name)
      mailbox.append!(id: "welcome-#{name}", author: author, attributes: { kind: "message", address: address, subject: subject, body: body })
      mailbox
    end
  end

  # Serialize sequence allocation and the write. A cursor can never skip a
  # lower revision that was still uncommitted when a peer polled.
  def append!(id:, author:, attributes:)
    with_lock do
      existing = mail_entries.find_by(id: id)
      if existing
        same = existing.author == author && attributes.all? { |field, value| existing[field] == value }
        raise ArgumentError, "Conflicting message" unless same
        return existing
      end
      entry = mail_entries.new(attributes.merge(id: id, author: author))
      case entry.kind
      when "message"
        raise ArgumentError, "Invalid email address" unless entry.address.to_s.match?(URI::MailTo::EMAIL_REGEXP) && entry.address.size <= 254
        raise ArgumentError, "Enter a subject and message" if entry.subject.blank? || entry.body.blank? || entry.parent_id.present?
      when "archive", "reply"
        raise ArgumentError, "Conversation unavailable" unless mail_entries.exists?(id: entry.parent_id, kind: "message")
        raise ArgumentError, "Enter a reply" if entry.kind == "reply" && entry.body.blank?
      end
      increment!(:revision)
      entry.update!(server_version: revision)
      entry
    end
  end
end
