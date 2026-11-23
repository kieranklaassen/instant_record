# The gem's 25s default window is sized for Puma, where a stream holds a
# thread. Under Falcon a stream is a fiber and minutes-long windows are the
# norm (Mercure defaults to 600s), so a deployment running Falcon can raise
# this without touching code. The reconnect is lossless either way — the
# cursor resumes from Last-Event-ID.
if (window = ENV["INSTANT_RECORD_SSE_WINDOW_SECONDS"])
  Rails.application.config.instant_record.sse_window_seconds = window.to_f
end

# Who a sync request comes from, in the two ways the demo knows a browser: the
# token it keeps for itself (the Assistant's `sync_scope :visitor_id`), and the
# person its session names (the Auth demo's `syncable_to` and `writable_by`).
# The key changes when the person does, which is what tells a browser to drop
# what it was sent as someone else.
DemoAsker = Struct.new(:token, :person_id) do
  def to_s = token.to_s
  def sync_identity_key = person_id || "anonymous"
  # The token never changes in a browser, so the Assistant's chats stay put
  # when the person does.
  def sync_reset_types = ["AuthNote"]
end

InstantRecord.configure do |config|
  config.scope_from = lambda do |request|
    DemoAsker.new(request.params["scope"], AuthPerson.known(request.session[:auth_person_id]))
  end
end

# The compiled demo includes MailEntry alongside the engine's Syncable models.
InstantRecord::Shell.models = %w[AssistantChat AssistantTurn AuthNote Channel ChatUser Issue MailEntry Message Note]
InstantRecord::Shell.identity_serializer = ->(asker) { [asker&.token, asker&.person_id] }
InstantRecord::Shell.identity_deserializer = ->(pair) { DemoAsker.new(*pair) }
InstantRecord::Shell.register(:mailbox) do |inbox|
  if (mailbox = Mailbox.find_by(id: inbox))
    {
      partition: mailbox.id,
      revision: -> { mailbox.reload.revision },
      identity_key: nil,
      snapshot: -> { mailbox.first_sync }
    }
  end
end
