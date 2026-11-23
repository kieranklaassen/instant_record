require "json"

module InstantRecord
  module Client
    module Transport
      class Error < StandardError
        attr_reader :status

        def initialize(message = nil, status: nil)
          super(message)
          @status = status.nil? ? parse_status(message) : status.to_i
        end

        def server_error?
          @status.is_a?(Integer) && @status >= 500 && @status < 600
        end

        private

        def parse_status(message)
          match = message.to_s.match(/->\s*(\d{3})\b/)
          match ? match[1].to_i : nil
        end
      end

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

        def get_json(path, headers: nil)
          JSON.parse(exchange("GET", path, "", headers: headers))
        rescue JSON::ParserError => e
          raise Error, "GET #{path} invalid JSON: #{e.message}"
        end

        def post_json(path, payload, headers: nil)
          JSON.parse(exchange("POST", path, JSON.generate(payload), headers: headers))
        rescue JSON::ParserError => e
          raise Error, "POST #{path} invalid JSON: #{e.message}"
        end

        # The host returns the whole catch-up stream at once (the loop polls with window=0).
        def each_event(path, headers: nil, &block)
          parser = SseParser.new(&block)
          parser.feed(exchange("GET", path, "", headers: headers))
        end

        private

        # Request file:
        #   Without headers: "METHOD URL\n<body>"
        #   With headers:    "METHOD URL\nName: Value\n...\n\n<body>"
        # Response file: first line the status, then the body. Status 0 is a network failure.
        def exchange(method, path, body, headers: nil)
          payload = format_request(method, "#{InstantRecord.config.endpoint}#{path}", body, headers)
          InstantRecord::Host.write_channel("request", payload)
          response = InstantRecord::Host.read_channel("response")
          newline = response.index("\n") || response.length
          status = response[0, newline].to_i
          raise Error.new("#{method} #{path} -> #{status}", status: status) unless status >= 200 && status < 300

          response[(newline + 1)..] || ""
        end

        def format_request(method, url, body, headers)
          return "#{method} #{url}\n#{body}" if headers.nil? || headers.empty?

          lines = []
          headers.each do |name, value|
            k = name.to_s.gsub(/[\r\n]/, "")
            v = value.to_s.gsub(/[\r\n]/, "")
            lines << "#{k}: #{v}" unless k.empty? || v.empty?
          end
          return "#{method} #{url}\n#{body}" if lines.empty?

          "#{method} #{url}\n#{lines.join("\n")}\n\n#{body}"
        end
      end
    end
  end
end
