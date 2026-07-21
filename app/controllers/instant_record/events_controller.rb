module InstantRecord
  class EventsController < ActionController::Base
    include ActionController::Live

    # SSE change stream. The change-log row id is the event id, which doubles
    # as the client's cursor (R9). Streams catch-up from ?after= (or the
    # Last-Event-ID reconnect header), then tails new changes for a bounded
    # window and closes — EventSource reconnects with the last id it saw.
    def index
      response.headers["Content-Type"] = "text/event-stream"
      response.headers["Cache-Control"] = "no-cache"
      response.headers["X-Accel-Buffering"] = "no"
      response.headers["Access-Control-Allow-Origin"] = "*"

      cursor = (request.headers["Last-Event-ID"] || params[:after] || 0).to_i
      deadline = Time.current + window_seconds

      loop do
        Change.after(cursor).each do |change|
          cursor = change.id
          response.stream.write("id: #{change.id}\n")
          response.stream.write("event: change\n")
          response.stream.write("data: #{change.as_event.to_json}\n\n")
        end

        break if Time.current >= deadline
        sleep 0.5
      end
    rescue IOError, ActionController::Live::ClientDisconnected
      # client went away; nothing to do
    ensure
      response.stream.close
    end

    private

    def window_seconds
      ENV.fetch("INSTANT_RECORD_SSE_WINDOW", Rails.env.test? ? "0" : "25").to_f
    end
  end
end
