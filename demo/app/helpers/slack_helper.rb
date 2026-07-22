module SlackHelper
  # The reset must hit the real server — only the server's change log
  # propagates to other clients. In the browser runtime, derive the URL from
  # the sync endpoint config: when the PWA is served cross-origin (Vite dev),
  # the endpoint is absolute and the service worker passes the request
  # straight to the network. When the endpoint is the same-origin default,
  # the ?instant_record_network=1 marker tells the service worker to bypass
  # the local wasm handler and send the request to the network.
  def slack_reset_endpoint
    return slack_reset_path unless InstantRecord.browser?

    base = InstantRecord.config.endpoint.to_s.sub(%r{/instant_record\z}, "")
    "#{base}#{slack_reset_path}?instant_record_network=1"
  end
end
