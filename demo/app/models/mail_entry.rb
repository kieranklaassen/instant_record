class MailEntry < ApplicationRecord
  PAGE_SIZE = 50
  scope :open_messages, -> { where(kind: "message").where("NOT EXISTS (SELECT 1 FROM mail_entries archived WHERE archived.parent_id = mail_entries.id AND archived.mailbox_id = mail_entries.mailbox_id AND archived.kind = 'archive')") }

  ACTIONS = %w[reply archive read unread].freeze
  # read and unread are one teammate's marks on a message, and the latest one
  # wins. With no mark, mail someone else wrote is unread and mail you sent is not.
  UNREAD = "COALESCE((SELECT mark.kind FROM mail_entries mark WHERE mark.parent_id = mail_entries.id AND mark.mailbox_id = mail_entries.mailbox_id AND mark.author = :member AND mark.kind IN ('read', 'unread') ORDER BY mark.created_at DESC, mark.server_version DESC LIMIT 1), CASE WHEN mail_entries.author = :member THEN 'read' ELSE 'unread' END) = 'unread'"

  validates :kind, inclusion: { in: %w[message reply archive read unread] }
  validates :subject, length: { maximum: 180 }
  validates :body, length: { maximum: 5000 }
end
