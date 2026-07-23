class Message < ApplicationRecord
  include InstantRecord::Syncable

  # Only the newest window per conversation syncs to fresh clients; older
  # pages stream in on demand as the visitor scrolls up.
  sync_window limit: 50, partition_by: :channel_id

  belongs_to :channel
  belongs_to :chat_user

  validates :body, presence: true

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
end
