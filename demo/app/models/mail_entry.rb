class MailEntry < ApplicationRecord
  include InstantRecord::Syncable

  PAGE_SIZE = 50
  FILL_PAGE_SIZE = 200
  # The most rows one live query of the list returns.
  LIVE_LIMIT = 5000
  scope :open_messages, -> { where(kind: "message").where("NOT EXISTS (SELECT 1 FROM mail_entries archived WHERE archived.parent_id = mail_entries.id AND archived.mailbox_id = mail_entries.mailbox_id AND archived.kind = 'archive')") }

  ACTIONS = %w[reply archive read unread].freeze
  # read and unread are one teammate's marks on a message, and the latest one
  # wins. With no mark, mail someone else wrote is unread and mail you sent is not.
  UNREAD = "COALESCE((SELECT mark.kind FROM mail_entries mark WHERE mark.parent_id = mail_entries.id AND mark.mailbox_id = mail_entries.mailbox_id AND mark.author = :member AND mark.kind IN ('read', 'unread') ORDER BY mark.created_at DESC, mark.server_version DESC LIMIT 1), CASE WHEN mail_entries.author = :member THEN 'read' ELSE 'unread' END) = 'unread'"

  # A search, said once for both databases: this runs on Postgres for the
  # server's page and on SQLite in the browser, so it is a plain LIKE over
  # lowered text. `%` and `_` in what the reader types match as LIKE reads them.
  # The two fold case alike for ASCII only: SQLite leaves "É" as it is where
  # Postgres lowers it, so a match on an accented capital is the server's alone.
  MATCHING = "(LOWER(mail_entries.subject) LIKE :q OR LOWER(mail_entries.body) LIKE :q OR LOWER(mail_entries.author) LIKE :q OR LOWER(mail_entries.address) LIKE :q)"

  sync_partition :mailbox_id

  def self.pattern(term)
    "%" + term.to_s.strip.downcase + "%"
  end

  validates :kind, inclusion: { in: %w[message reply archive read unread] }
  validates :subject, length: { maximum: 180 }
  validates :body, length: { maximum: 5000 }

  server_only do
    # First-sync bootstrap, keyset paging, search widening, thread lookup, and
    # background history-fill — declared on the model so InstantRecord::Engine
    # serves the Inbox with no custom sync controller.
    sync_shape limit: PAGE_SIZE,
               min_limit: PAGE_SIZE,
               max_limit: FILL_PAGE_SIZE,
               roots: -> { open_messages },
               include: ->(roots) { where(parent_id: roots.map(&:id), kind: ACTIONS).order(:created_at, :server_version, :id) },
               search: ->(term) { where(MATCHING, q: pattern(term)) },
               lookup: ->(id) { where(id: id, kind: "message") },
               background_fill: true

    authorize_partition do |inbox, asker|
      next false unless asker&.member && MailDirectory.inboxes(asker.member).include?(inbox)

      Mailbox.open_demo(inbox)
      true
    end

    # Entries are append-only and must be authored by the requesting member.
    writable_by(only: :create) do |asker|
      asker&.member ? where(author: asker.member) : none
    end

    validate :valid_entry_payload, on: :create

    def valid_entry_payload
      unless id.to_s.match?(/\A[\w-]{1,80}\z/)
        errors.add(:id, "is invalid")
      end

      case kind
      when "message"
        unless address.to_s.match?(URI::MailTo::EMAIL_REGEXP) && address.to_s.size <= 254
          errors.add(:address, "is not a valid email address")
        end
        errors.add(:base, "Enter a subject and message") if subject.blank? || body.blank? || parent_id.present?
      when "archive", "reply", "read", "unread"
        unless MailEntry.exists?(id: parent_id, mailbox_id: mailbox_id, kind: "message")
          errors.add(:parent_id, "conversation unavailable")
        end
        errors.add(:body, "can't be blank") if kind == "reply" && body.blank?
      end
    end
  end
end
