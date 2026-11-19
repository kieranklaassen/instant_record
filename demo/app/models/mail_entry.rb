class MailEntry < ApplicationRecord
  validates :kind, inclusion: { in: %w[message reply archive] }
  validates :subject, length: { maximum: 180 }
  validates :body, length: { maximum: 5000 }
end
