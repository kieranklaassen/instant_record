class MailEntry < ApplicationRecord
  PAGE_SIZE = 50
  scope :open_messages, -> { where(kind: "message").where("NOT EXISTS (SELECT 1 FROM mail_entries archived WHERE archived.parent_id = mail_entries.id AND archived.mailbox_id = mail_entries.mailbox_id AND archived.kind = 'archive')") }

  validates :kind, inclusion: { in: %w[message reply archive] }
  validates :subject, length: { maximum: 180 }
  validates :body, length: { maximum: 5000 }
end
