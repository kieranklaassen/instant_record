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

      # Browser implementation over the JS fetch API via ruby.wasm's `js`
      # gem. Every `.await` is an asyncify suspension point, so this class
      # must only run under `evalAsync`.
      class JsFetch
        def initialize
          require "js"
        end

        def post_json(path, payload)
          options = JS.eval("return {}")
          options[:method] = "POST"
          headers = JS.eval("return {}")
          headers["Content-Type"] = "application/json"
          options[:headers] = headers
          options[:body] = JSON.generate(payload)

          response = JS.global.fetch(url(path), options).await
          raise Error, "POST #{path} -> #{response[:status]}" unless response[:ok] == JS::True

          JSON.parse(response.text.await.to_s)
        end

        # Streams an SSE response, yielding one parsed event hash at a time.
        # The server closes its bounded window; we return when the body ends.
        def each_event(path, &block)
          response = JS.global.fetch(url(path)).await
          raise Error, "GET #{path} -> #{response[:status]}" unless response[:ok] == JS::True

          parser = SseParser.new(&block)
          reader = response[:body].getReader
          decoder = JS.global[:TextDecoder].new
          @stream_options ||= JS.eval("return {stream: true}")

          loop do
            result = reader.read.await
            break if result[:done] == JS::True

            parser.feed(decoder.decode(result[:value], @stream_options).to_s)
          end
        end

        private

        def url(path)
          "#{InstantRecord.config.endpoint}#{path}"
        end
      end
    end
  end
end
