InstantRecord.configure do |config|
  # When the PWA is served by the Vite dev server (:5173), the sync server is
  # the Rails app on :3000 — cross-origin, so derive an absolute endpoint.
  # Served any other way (the Rails app itself, a tunnel, production), the
  # same-origin default ("/instant_record") is already right.
  if InstantRecord.browser?
    begin
      require "js"
      location = JS.global[:location]
      if location[:port].to_s == "5173"
        config.endpoint = "http://#{location[:hostname]}:3000/instant_record"
      end
    rescue LoadError
      # wasm without a JS host (e.g. wasmtime/WASI verify builds): the js gem
      # is excluded there; the same-origin default applies.
    end
  end
end

# The gem's 25s default window is sized for Puma, where a stream holds a
# thread. Under Falcon a stream is a fiber and minutes-long windows are the
# norm (Mercure defaults to 600s), so a deployment running Falcon can raise
# this without touching code. The reconnect is lossless either way — the
# cursor resumes from Last-Event-ID.
if (window = ENV["INSTANT_RECORD_SSE_WINDOW_SECONDS"])
  Rails.application.config.instant_record.sse_window_seconds = window.to_f
end
