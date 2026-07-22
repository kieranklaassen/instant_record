#!/usr/bin/env ruby
# SSE load spike: opens N idle EventSource-style connections, then fires one
# mutation and measures how long the resulting change event takes to reach
# every connected client.
#
# Usage (from demo/):
#   SPIKE_AFTER=$(bin/rails runner 'print InstantRecord::Change.maximum(:id).to_i')
#   SPIKE_URL=http://localhost:3001 SPIKE_CONNECTIONS=200 SPIKE_AFTER=$SPIKE_AFTER \
#     bundle exec ruby script/sse_load_spike.rb

require "bundler/setup"
require "async"
require "async/barrier"
require "async/http/internet"
require "json"
require "securerandom"

url   = ENV.fetch("SPIKE_URL", "http://localhost:3000")
n     = Integer(ENV.fetch("SPIKE_CONNECTIONS", "200"))
after = Integer(ENV.fetch("SPIKE_AFTER"))

stats = { connected: 0, delivered: 0, latencies: [], errors: 0 }
fired_at = nil

monotonic = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
started = monotonic.call

Async do |task|
  internet = Async::HTTP::Internet.new
  barrier = Async::Barrier.new

  n.times do
    barrier.async do
      response = internet.get("#{url}/instant_record/events?after=#{after}", [["accept", "text/event-stream"]])
      stats[:connected] += 1
      buffer = +""
      response.body.each do |chunk|
        buffer << chunk
        if buffer.include?("event: change")
          stats[:delivered] += 1
          stats[:latencies] << (monotonic.call - fired_at) if fired_at
          break
        end
      end
    rescue StandardError
      stats[:errors] += 1
    ensure
      response&.close
    end
  end

  # Fire one mutation once every client is connected (or after a grace period).
  task.async do
    deadline = monotonic.call + 15
    sleep 0.1 while stats[:connected] < n && monotonic.call < deadline

    fired_at = monotonic.call
    internet.post(
      "#{url}/instant_record/mutations",
      [["content-type", "application/json"]],
      JSON.dump(mutations: [{
        id: SecureRandom.uuid,
        record_type: "Issue",
        record_id: SecureRandom.uuid,
        operation: "create",
        base_version: 0,
        changes: { title: "spike #{Time.now.utc.iso8601}", state: "open", updated_at: Time.now.utc.iso8601 }
      }])
    ).finish
  end

  task.with_timeout(40) { barrier.wait }
rescue Async::TimeoutError
  warn "timed out waiting for all streams"
ensure
  internet&.close
end

latencies = stats[:latencies].sort
pct = ->(p) { latencies.empty? ? nil : latencies[[(latencies.size * p).ceil - 1, 0].max] }

puts JSON.pretty_generate(
  url: url,
  connections_requested: n,
  connected: stats[:connected],
  delivered: stats[:delivered],
  errors: stats[:errors],
  latency_ms: latencies.empty? ? nil : {
    p50: (pct.(0.50) * 1000).round,
    p95: (pct.(0.95) * 1000).round,
    max: (latencies.last * 1000).round
  },
  total_seconds: (monotonic.call - started).round(1)
)
