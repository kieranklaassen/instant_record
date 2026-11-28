require "instant_record/sync_endpoint"

module InstantRecord
  class EventsController < ActionController::Base
    include SyncEndpoint

    # SSE change stream as a lazily-enumerated response body — not
    # ActionController::Live (which burns a thread per stream and bypasses the
    # fiber scheduler). An #each body is the portable Rack streaming
    # interface: Puma and Falcon both write each chunk as it is yielded.
    # Under Falcon each stream is a fiber, so `sleep` and pg queries suspend
    # the fiber; under Puma the body holds the request thread.
    #
    # The change-log row id is the event id, which doubles as the client's
    # cursor: catch-up from ?after= (or the Last-Event-ID reconnect header),
    # then tail for a bounded window and close. ?window= lets a client shorten
    # the tail — the gem's own sync loop polls with window=0 (catch-up only)
    # so a tick never holds a long stream.
    EVENT_STREAM_HEADERS = {
      "content-type" => "text/event-stream",
      "cache-control" => "no-store",
      "x-accel-buffering" => "no"
    }.freeze

    class EventStream
      # `identity` and `partition` are fixed when the stream opens.
      def initialize(cursor:, deadline:, heartbeat: 15.0, identity: nil, partition: nil, partition_spec: nil)
        @cursor = cursor
        @identity = identity
        @partition = partition
        @partition_spec = partition_spec
        @deadline = deadline
        @heartbeat = heartbeat
        @last_write = Time.current
      end

      def each
        loop do
          changes = Change.poll(@cursor, scope: SyncScope.token(@identity), partition: @partition)
          SyncScope.events_for(changes, @identity, partition: @partition_spec).each do |id, event|
            @cursor = id
            # Time.now, not Time.current: an elapsed time needs no zone, and
            # this runs once per event.
            @last_write = Time.now
            event[:server_time] = InstantRecord::HLC.iso_now
            yield "id: #{id}\nevent: change\ndata: #{event.to_json}\n\n"
          end

          # An SSE comment, written only when the stream has been quiet for a
          # full interval. Keeps idle-connection reapers (reverse proxies) at
          # bay, and doubles as the write that discovers a vanished client.
          if @heartbeat.positive? && Time.current - @last_write >= @heartbeat
            @last_write = Time.current
            yield ": hb\n\n"
          end

          break if Time.current >= @deadline
          sleep 0.5
        end
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError
        # The client hung up mid-stream — the normal end of an SSE stream.
      end
    end

    def index
      cursor = (request.headers["Last-Event-ID"] || params[:after] || 0).to_i

      SyncScope.authenticate!(request)
      identity = SyncScope.identity(request)
      partition_spec = SyncScope.partition(request, identity)
      eager_load_models!
      models = SyncScope.models_for(partition_spec)
      SyncScope.authorize_models!(models, partition_spec, identity, request)
      change_partitions = SyncScope.change_partitions_for(models, partition_spec)

      headers.merge!(EVENT_STREAM_HEADERS)

      # A client that synced as someone else is told to start over, and nothing
      # more: no id line, so the cursor it is about to drop does not move.
      if SyncScope.stale?(params[:identity], identity, partition: partition_spec)
        reset_payload = SyncScope.reset_event(identity, partition: partition_spec).merge(server_time: InstantRecord::HLC.iso_now)
        self.response_body = ["event: reset\ndata: #{reset_payload.to_json}\n\n"]
        return
      end

      self.response_body = EventStream.new(
        cursor: cursor,
        identity: identity,
        partition: change_partitions,
        partition_spec: partition_spec,
        deadline: Time.current + window_seconds,
        heartbeat: Rails.application.config.instant_record.sse_heartbeat_seconds.to_f
      )
    end

    private

    def window_seconds
      configured = Rails.application.config.instant_record.sse_window_seconds.to_f
      requested = params[:window]&.to_f
      seconds = requested ? requested.clamp(0.0, configured) : configured

      # +/-10% jitter so a herd of streams opened together doesn't reconnect
      # in lockstep at every window boundary.
      seconds.positive? ? seconds * (0.9 + rand * 0.2) : seconds
    end
  end
end
