if defined?(Rack::Attack)
  Rack::Attack.throttle("mutations/ip", limit: 120, period: 1.minute) do |req|
    req.ip if req.post? && req.path == "/instant_record/mutations"
  end

  Rack::Attack.throttle("reset/ip", limit: 4, period: 1.minute) do |req|
    req.ip if req.post? && req.path == "/slack/reset"
  end

  # Each of these may be a paid model call (see Assistant::Reply).
  Rack::Attack.throttle("assistant/ip", limit: 30, period: 1.minute) do |req|
    req.ip if req.post? && req.path.match?(%r{\A/+assistant/turns(\.\w+)?/*\z})
  end

  Rack::Attack.throttle("writes/ip", limit: 60, period: 1.minute) do |req|
    req.ip if req.post? && req.path != "/instant_record/mutations" && req.path != "/slack/reset"
  end
end
