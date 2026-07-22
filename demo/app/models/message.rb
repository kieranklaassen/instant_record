class Message < ApplicationRecord
  include InstantRecord::Syncable

  belongs_to :channel
  belongs_to :chat_user

  validates :body, presence: true

  def from_visitor? = chat_user_id == ChatUser::VISITOR_ID
end
