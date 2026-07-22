module SlackHelper
  # The reset must hit the real server — only the server's change log
  # propagates to other clients. In the browser runtime, derive the URL from
  # the sync endpoint config: when the PWA is served cross-origin (Vite dev),
  # the endpoint is absolute and the service worker passes the request
  # straight to the network instead of handling it locally. When the endpoint
  # is the same-origin default, this yields a relative URL and the service
  # worker's /slack/reset network passthrough keeps it off the wasm handler.
  def slack_reset_endpoint
    return slack_reset_path unless InstantRecord.browser?

    InstantRecord.config.endpoint.to_s.sub(%r{/instant_record\z}, "") + slack_reset_path
  end
end
