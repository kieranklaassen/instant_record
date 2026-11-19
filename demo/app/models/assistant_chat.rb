# One conversation with the Assistant. A chat and its turns are ordinary synced
# records: every browser holds them in local SQLite, and Rails holds them in Postgres.
class AssistantChat < ApplicationRecord
  include InstantRecord::Syncable

  # The conversations that ship with the demo (db/seeds/assistant_chats.rb).
  EXAMPLES = %w[chat-scrollback inbox-delivery offline-todos].freeze

  has_many :assistant_turns, dependent: :destroy

  validates :title, presence: true, length: { maximum: 120 }
end
