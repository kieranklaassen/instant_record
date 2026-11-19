# A question and its answer. The question is saved the moment it is asked, online
# or off; the answer is written onto the same record by whoever was asked.
class AssistantTurn < ApplicationRecord
  include InstantRecord::Syncable

  ENGINES = %w[server local].freeze
  LOCAL_AUTHOR = "On-device model"
  MAX_REPLY = 20_000

  # A turn is its visitor's own, also when it follows up on an example chat.
  sync_scope :visitor_id

  belongs_to :assistant_chat

  validates :prompt, presence: true, length: { maximum: 8_000 }
  validates :reply, length: { maximum: MAX_REPLY }
  validates :engine, inclusion: { in: ENGINES }

  def answered? = reply != ""

  # Only Rails asks a model provider. The job exists on the server alone, and its
  # answer reaches every browser the way any record does: change log, then sync.
  server_only do
    after_create_commit -> { Assistant::ReplyJob.perform_later(id) if engine == "server" && !answered? }
  end
end
