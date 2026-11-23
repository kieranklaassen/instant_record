# The gem's 25s default window is sized for Puma, where a stream holds a
# thread. Under Falcon a stream is a fiber and minutes-long windows are the
# norm (Mercure defaults to 600s), so a deployment running Falcon can raise
# this without touching code. The reconnect is lossless either way — the
# cursor resumes from Last-Event-ID.
if (window = ENV["INSTANT_RECORD_SSE_WINDOW_SECONDS"])
  Rails.application.config.instant_record.sse_window_seconds = window.to_f
end

# Who a sync request comes from, in the three ways the demo knows a client:
# the browser token (Assistant's `sync_scope :visitor_id`), the session person
# (Auth demo's `syncable_to` / `writable_by`), and the Inbox member
# (`X-Instant-Record-Member` / Bearer token for `MailEntry`'s `sync_partition`).
DemoAsker = Struct.new(:token, :person_id, :member) do
  def to_s = token.to_s

  def sync_identity_key
    base = person_id || "anonymous"
    member.present? ? "#{base}:#{member}" : base
  end

  # The token never changes in a browser, so the Assistant's chats stay put
  # when the person does.
  def sync_reset_types = ["AuthNote"]
end

InstantRecord.configure do |config|
  # Validate Bearer tokens whenever an Authorization header is sent, or when
  # INBOX_REQUIRE_TOKEN is set on a partitioned inbox request.
  config.authenticate_request = lambda do |request|
    auth = request.authorization.to_s
    sent = auth[/\ABearer (.+)\z/, 1]
    partition = request.headers["X-Instant-Record-Partition"].presence || request.params["sync_partition"].presence
    member = request.headers["X-Instant-Record-Member"].presence || request.params["member"].presence

    if auth.present?
      raise InstantRecord::Unauthorized if sent.nil?

      verified = MailDirectory.member_for(sent)
      raise InstantRecord::Unauthorized unless verified
      raise InstantRecord::Unauthorized if member.present? && verified != member
    elsif partition.present? && ENV["INBOX_REQUIRE_TOKEN"].present?
      raise InstantRecord::Unauthorized
    end
  end

  config.scope_from = lambda do |request|
    scope_header = request.headers["X-Instant-Record-Scope"].presence
    visitor = scope_header || request.params["scope"].presence
    person = AuthPerson.known(request.session[:auth_person_id])
    sent = request.authorization.to_s[/\ABearer (.+)\z/, 1]
    member = request.headers["X-Instant-Record-Member"].presence ||
             request.params["member"].presence ||
             (sent && MailDirectory.member_for(sent))
    DemoAsker.new(visitor, person, member)
  end
end

# The compiled demo includes MailEntry alongside the engine's Syncable models.
InstantRecord::Shell.models = %w[AssistantChat AssistantTurn AuthNote Channel ChatUser Issue MailEntry Message Note]
InstantRecord::Shell.identity_serializer = ->(asker) { [asker&.token, asker&.person_id, asker&.member] }
InstantRecord::Shell.identity_deserializer = ->(tuple) { DemoAsker.new(*tuple) }
InstantRecord::Shell.register(:mailbox) do |inbox|
  if (mailbox = Mailbox.find_by(id: inbox))
    {
      partition: mailbox.id,
      revision: -> { InstantRecord::Change.maximum(:id) || 0 },
      identity_key: nil,
      snapshot: -> { mailbox.first_sync }
    }
  end
end
