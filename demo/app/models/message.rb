class Message < ApplicationRecord
  include InstantRecord::Syncable

  # Only the newest window per conversation syncs to fresh clients; older
  # pages stream in on demand as the visitor scrolls up.
  sync_window limit: 50, partition_by: :channel_id

  belongs_to :channel
  belongs_to :chat_user

  # Threads: a reply is an ordinary Message pointing at its parent, so it syncs
  # through the same outbox and change log as everything else — no second data
  # path. The conversation shows top-level rows; replies render in the thread
  # panel. dependent: :destroy keeps the reset sweep and a deleted parent from
  # stranding orphan replies.
  belongs_to :parent_message, class_name: "Message", optional: true
  has_many :replies, class_name: "Message", foreign_key: :parent_message_id,
    inverse_of: :parent_message, dependent: :destroy

  scope :top_level, -> { where(parent_message_id: nil) }

  validates :body, presence: true, length: { maximum: 2_000 }
  # A reply must live in its parent's conversation; anything else renders
  # nowhere and would sit in the database as unreachable state.
  validate :parent_in_same_channel

  def thread_reply? = parent_message_id.present?

  # Fake replies are a server concern: the job is enqueued only where it can
  # run, and the reply syncs back to browsers through the change log + SSE.
  server_only do
    after_create_commit :enqueue_fake_reply
  end

  def from_visitor? = chat_user_id == ChatUser::VISITOR_ID

  private

  # Only visitor-authored messages draw a reply; bot messages never do, so
  # replies cannot cascade into a loop.
  def enqueue_fake_reply
    return unless from_visitor?

    Slack::FakeReplyJob.set(wait: rand(1.0..3.0).seconds).perform_later(id)
  end

  def parent_in_same_channel
    return if parent_message_id.blank?
    return if parent_message&.channel_id == channel_id && !parent_message.thread_reply?

    errors.add(:parent_message, "must be a top-level message in the same channel")
  end
end
