InstantRecord.configure do |config|
  # When the PWA is served by the Vite dev server (:5173), the sync server is
  # the Rails app on :3000 — cross-origin, so derive an absolute endpoint.
  # Served any other way (the Rails app itself, a tunnel, production), the
  # same-origin default ("/instant_record") is already right.
  if InstantRecord.browser?
    require "js"
    location = JS.global[:location]
    if location[:port].to_s == "5173"
      config.endpoint = "http://#{location[:hostname]}:3000/instant_record"
    end
  end
end
