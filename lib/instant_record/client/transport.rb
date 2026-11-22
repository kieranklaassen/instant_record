require "json"

module InstantRecord
  module Client
    module Transport
      Error = Class.new(StandardError)

      # Incremental parser for text/event-stream bodies. Pure Ruby so the
      # sync loop is unit-testable without a browser. Yields one hash per
      # event, with the SSE id merged in as "cursor".
      class SseParser
        def initialize(&on_event)
          @buffer = +""
          @on_event = on_event
        end

        def feed(chunk)
          @buffer << chunk

          while (separator = @buffer.index("\n\n"))
            raw_event = @buffer.slice!(0, separator + 2)

            id = raw_event[/^id: (.+)$/, 1]
            data = raw_event[/^data: (.+)$/, 1]
            next unless data

            event = JSON.parse(data)
            event["cursor"] = id.to_i if id
            @on_event.call(event)
          end
        end
      end

      # The dedicated worker supplies network responses through the WASI host.
      class WorkerFetch
        REQUEST = "/host/request".freeze
        RESPONSE = "/host/response".freeze

        def get_json(path)
          JSON.parse(exchange("GET", path, ""))
        end

        def post_json(path, payload)
          JSON.parse(exchange("POST", path, JSON.generate(payload)))
        end

        # The host returns the whole catch-up stream at once (the loop polls with window=0).
        def each_event(path, &block)
          parser = SseParser.new(&block)
          parser.feed(exchange("GET", path, ""))
        end

        private

        # Request file: first line "METHOD URL", then the body. Response file: first line the
        # status, then the body. Status 0 is a network failure.
        def exchange(method, path, body)
          InstantRecord::Host.write_channel("request", "#{method} #{InstantRecord.config.endpoint}#{path}\n#{body}")
          response = InstantRecord::Host.read_channel("response")
          newline = response.index("\n") || response.length
          status = response[0, newline].to_i
          raise Error, "#{method} #{path} -> #{status}" unless status >= 200 && status < 300

          response[(newline + 1)..] || ""
        end
      end
    end
  end
end
