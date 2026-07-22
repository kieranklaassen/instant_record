class ChatUser < ApplicationRecord
  include InstantRecord::Syncable

  VISITOR_ID = "you".freeze

  validates :name, :handle, presence: true

  scope :bots, -> { where(bot: true) }

  def self.visitor
    find(VISITOR_ID)
  end

  def visitor? = id == VISITOR_ID
end
