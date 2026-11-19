# The gem's 25s default window is sized for Puma, where a stream holds a
# thread. Under Falcon a stream is a fiber and minutes-long windows are the
# norm (Mercure defaults to 600s), so a deployment running Falcon can raise
# this without touching code. The reconnect is lossless either way — the
# cursor resumes from Last-Event-ID.
if (window = ENV["INSTANT_RECORD_SSE_WINDOW_SECONDS"])
  Rails.application.config.instant_record.sse_window_seconds = window.to_f
end

# Who a sync request comes from: the person the Auth demo's session names, or
# nobody. Models that declare `syncable_to` are sent, and written, by this.
InstantRecord.configure do |config|
  config.sync_identity = ->(request) { AuthPerson.find(request.session[:auth_person_id]) }
end
