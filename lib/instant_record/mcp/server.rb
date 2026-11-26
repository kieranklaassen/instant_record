require "json"

module InstantRecord
  module Mcp
    # Model Context Protocol (MCP) JSON-RPC 2.0 server over stdio.
    #
    # Reads newline-delimited JSON-RPC messages from `input` ($stdin) and writes
    # newline-delimited JSON-RPC responses to `output` ($stdout). Diagnostic logs
    # never touch `output` — they go to `err` ($stderr).
    class Server
      JSONRPC_VERSION = "2.0".freeze
      SUPPORTED_PROTOCOLS = %w[2025-06-18 2025-03-26 2024-11-05].freeze
      DEFAULT_PROTOCOL = "2024-11-05".freeze

      PARSE_ERROR = -32700
      INVALID_REQUEST = -32600
      METHOD_NOT_FOUND = -32601
      INVALID_PARAMS = -32602
      INTERNAL_ERROR = -32603

      def initialize(runtime, input: $stdin, output: $stdout, err: $stderr, name: "instant_record", version: InstantRecord::VERSION)
        @runtime = runtime
        @input = input
        @output = output
        @err = err
        @name = name
        @version = version
        @output.sync = true if @output.respond_to?(:sync=)
      end

      def run
        with_utf8_streams { serve }
      end

      def handle_line(line)
        return error_response(nil, PARSE_ERROR, "Parse error: invalid UTF-8") unless line.valid_encoding?

        message = JSON.parse(line)
        handle_message(message)
      rescue JSON::ParserError => e
        error_response(nil, PARSE_ERROR, "Parse error: #{e.message}")
      end

      def handle_message(message)
        unless message.is_a?(Hash) && message["jsonrpc"] == JSONRPC_VERSION && message["method"].is_a?(String)
          return error_response(message.is_a?(Hash) ? message["id"] : nil, INVALID_REQUEST, "Invalid JSON-RPC 2.0 request")
        end

        id = message["id"]
        method = message["method"]
        params = message["params"] || {}
        notification = !message.key?("id")

        case method
        when "initialize"
          result_response(id, handle_initialize(params))
        when "notifications/initialized", "notifications/cancelled", "initialized"
          nil
        when "ping"
          result_response(id, {})
        when "tools/list"
          result_response(id, { "tools" => tool_definitions })
        when "tools/call"
          result_response(id, handle_tool_call(params))
        when "resources/list"
          result_response(id, { "resources" => resource_definitions })
        when "resources/read"
          result_response(id, handle_resource_read(params))
        else
          error_response(id, METHOD_NOT_FOUND, "Method not found: #{method}") unless notification
        end
      rescue ArgumentError => e
        error_response(id, INVALID_PARAMS, e.message) unless notification
      rescue StandardError => e
        @err&.puts("[instant_record:mcp] #{e.class}: #{utf8(e.message)}")
        error_response(id, INTERNAL_ERROR, e.message) unless notification
      end

      def tool_definitions
        [
          tool("instant_record_status", "Inspect local SQLite replica sync cursor, pending outbox count, identity, models, and available screens (<1ms offline)."),
          tool(
            "instant_record_sync",
            "Run a sync pass against the configured Rails server: push pending local outbox mutations and pull latest scoped changes.",
            properties: {
              "endpoint" => { "type" => "string", "description" => "Optional sync endpoint URL override." }
            }
          ),
          tool("instant_record_models", "List all synced models in the local SQLite replica with table names, columns, row counts, and pending write counts (<1ms offline)."),
          tool(
            "instant_record_query",
            "Query synced model records from the local SQLite replica with structured filters, sorting, column projection, and pagination (<1ms offline).",
            required: ["model"],
            properties: {
              "model" => { "type" => "string", "description" => "Synced model or table name (e.g. Issue, Note, MailEntry)." },
              "where" => {
                "type" => "object",
                "description" => "Column filters: exact values, arrays (IN), null (IS NULL), or operator objects ({eq, ne, gt, gte, lt, lte, like, in, is_null, not_null})."
              },
              "order" => {
                "oneOf" => [
                  { "type" => "string" },
                  { "type" => "array", "items" => { "type" => "string" } }
                ],
                "description" => "Sort order such as 'created_at desc' or ['created_at desc', 'id desc']."
              },
              "columns" => string_list_schema("Optional subset of columns to return."),
              "limit" => limit_schema(50),
              "offset" => { "type" => "integer", "minimum" => 0, "default" => 0 }
            }
          ),
          tool(
            "instant_record_get",
            "Fetch a single synced record by model and primary key ID from the local SQLite replica (<1ms offline).",
            required: %w[model id],
            properties: {
              "model" => { "type" => "string", "description" => "Synced model or table name." },
              "id" => { "type" => "string", "description" => "Primary key value." }
            }
          ),
          tool(
            "instant_record_search",
            "Case-insensitive multi-term search across one or all synced models in the local SQLite replica (<1ms offline).",
            required: ["query"],
            properties: {
              "query" => { "type" => "string", "description" => "Search query string (whitespace-separated terms must all match)." },
              "models" => string_list_schema("Optional list of models to restrict search to."),
              "columns" => string_list_schema("Optional list of columns to search (when restricting to models that share those columns)."),
              "limit" => limit_schema(50)
            }
          ),
          tool(
            "instant_record_outbox",
            "Inspect locally queued offline outbox mutations waiting to sync to the server (<1ms offline).",
            properties: {
              "limit" => limit_schema(100)
            }
          ),
          tool(
            "instant_record_render_screen",
            "Render a compiled native screen (app/screens/*_screen.rb) from the local SQLite replica as structured JSON (<1ms offline).",
            required: ["screen"],
            properties: {
              "screen" => { "type" => "string", "description" => "Screen name (e.g. mailbox, thread)." },
              "params" => { "type" => "object", "description" => "Screen parameters (string key/value pairs)." }
            }
          ),
          tool(
            "instant_record_action",
            "Execute a validated local native screen action (Screen#perform) inside the compiled host offline, running validations and queueing outbox mutations (<1ms offline).",
            required: %w[screen action],
            properties: {
              "screen" => { "type" => "string", "description" => "Screen name." },
              "action" => { "type" => "string", "description" => "Action name passed to Screen#perform." },
              "params" => { "type" => "object", "description" => "Screen parameters." },
              "args" => { "type" => "object", "description" => "Action arguments." },
              "values" => { "type" => "object", "description" => "Form field values." },
              "render" => { "type" => "boolean", "description" => "Re-render the screen after the action.", "default" => false },
              "sync" => { "type" => "boolean", "description" => "Run a sync pass immediately after the action.", "default" => false }
            }
          ),
          tool(
            "instant_record_request",
            "Dispatch a validated local HTTP request (GET/POST/PATCH/DELETE) through the compiled Rails app inside the native host offline, running controller & model validations and queueing outbox mutations (<1ms offline).",
            required: %w[method path],
            properties: {
              "method" => { "type" => "string", "enum" => %w[GET POST PATCH PUT DELETE], "description" => "HTTP method." },
              "path" => { "type" => "string", "description" => "Application path (e.g. /todo/issues)." },
              "params" => { "type" => "object", "description" => "Request parameters (encoded as query string for GET, form or JSON for writes)." },
              "body" => { "type" => "string", "description" => "Optional raw request body." },
              "content_type" => { "type" => "string", "description" => "Optional Content-Type header." },
              "headers" => { "type" => "object", "description" => "Optional HTTP headers." },
              "sync" => { "type" => "boolean", "description" => "Run a sync pass after a successful request.", "default" => false }
            }
          ),
          tool(
            "instant_record_history",
            "Inspect local history pagination state or fetch an older keyset history page from the server into the local SQLite replica.",
            required: ["key"],
            properties: {
              "key" => { "type" => "string", "description" => "History pagination key (e.g. older:support)." },
              "query" => { "type" => "string", "description" => "Optional /records query string to fetch from the server." },
              "endpoint" => { "type" => "string", "description" => "Optional sync endpoint override." }
            }
          )
        ]
      end

      def resource_definitions
        base = [
          resource("status", "Replica Status", "Current sync cursor, pending outbox count, identity, and local SQLite replica metadata."),
          resource("models", "Synced Models", "Schema and row counts for every synced model in the local SQLite replica."),
          resource("outbox", "Pending Outbox Mutations", "Queued offline mutations waiting to sync to the Rails server.")
        ]

        @runtime.list_models["models"].each do |model|
          base << resource(
            "models/#{model['name']}",
            "#{model['name']} Records",
            "Recent records of #{model['name']} (#{model['count']} local rows)."
          )
        end
        base
      end

      private

      # MCP is UTF-8 both ways, so no stream may convert to or from the locale's
      # encoding. The server reads and writes copies: the caller's streams keep
      # their own encodings.
      def with_utf8_streams
        originals = [@input, @output, @err]
        copies = []
        @input, @output, @err = originals.map do |io|
          next io unless io.is_a?(IO)

          copies << (copy = io.dup)
          copy.set_encoding(io.equal?(originals.first) ? Encoding::BINARY : Encoding::UTF_8, nil)
          copy.sync = true
          copy
        end
        yield
      ensure
        @input, @output, @err = originals
        copies.each(&:close)
      end

      def serve
        while (line = @input.gets)
          line.force_encoding(Encoding::UTF_8)
          if line.valid_encoding?
            line = line.strip
            next if line.empty?
          end

          response = handle_line(line)
          write_response(response) if response
        end
      end

      def tool(name, description, properties: {}, required: nil)
        schema = { "type" => "object", "properties" => properties }
        schema["required"] = required if required
        schema["additionalProperties"] = false
        { "name" => name, "description" => description, "inputSchema" => schema }
      end

      def limit_schema(default)
        { "type" => "integer", "minimum" => 1, "maximum" => 500, "default" => default }
      end

      def string_list_schema(description)
        { "type" => "array", "items" => { "type" => "string" }, "description" => description }
      end

      def resource(path, name, description)
        {
          "uri" => "instant-record://#{path}",
          "name" => name,
          "description" => description,
          "mimeType" => "application/json"
        }
      end

      def handle_initialize(params)
        requested = params["protocolVersion"].to_s
        negotiated = SUPPORTED_PROTOCOLS.include?(requested) ? requested : DEFAULT_PROTOCOL
        {
          "protocolVersion" => negotiated,
          "capabilities" => {
            "tools" => {},
            "resources" => {}
          },
          "serverInfo" => {
            "name" => @name,
            "version" => @version
          }
        }
      end

      def handle_tool_call(params)
        name = params["name"].to_s
        args = params["arguments"] || {}
        raise ArgumentError, "Tool arguments must be an object" unless args.is_a?(Hash)

        data = dispatch_tool(name, args)
        is_error = data.is_a?(Hash) && data.key?("ok") && data["ok"] == false
        tool_result(data, is_error: is_error)
      rescue ArgumentError, Error => e
        tool_result({ "ok" => false, "error" => e.message }, is_error: true)
      end

      def dispatch_tool(name, args)
        case name
        when "instant_record_status"
          @runtime.status
        when "instant_record_sync"
          @runtime.sync(endpoint: args["endpoint"])
        when "instant_record_models"
          @runtime.list_models
        when "instant_record_query"
          @runtime.query_records(
            model: required_argument(args, "model"),
            where: args["where"] || {},
            order: args["order"],
            limit: args["limit"] || Replica::DEFAULT_LIMIT,
            offset: args["offset"] || 0,
            columns: args["columns"]
          )
        when "instant_record_get"
          @runtime.get_record(
            model: required_argument(args, "model"),
            id: required_argument(args, "id")
          )
        when "instant_record_search"
          @runtime.search_records(
            query: required_argument(args, "query"),
            models: args["models"],
            columns: args["columns"],
            limit: args["limit"] || Replica::DEFAULT_LIMIT
          )
        when "instant_record_outbox"
          @runtime.outbox(limit: args["limit"] || 100)
        when "instant_record_render_screen"
          @runtime.render_screen(
            screen: required_argument(args, "screen"),
            params: args["params"] || {}
          )
        when "instant_record_action"
          @runtime.perform_action(
            screen: required_argument(args, "screen"),
            action: required_argument(args, "action"),
            params: args["params"] || {},
            args: args["args"] || {},
            values: args["values"] || {},
            render: !!args["render"],
            sync: !!args["sync"]
          )
        when "instant_record_request"
          @runtime.app_request(
            method: required_argument(args, "method"),
            path: required_argument(args, "path"),
            params: args["params"],
            body: args["body"],
            headers: args["headers"] || {},
            content_type: args["content_type"],
            sync: !!args["sync"]
          )
        when "instant_record_history"
          @runtime.fetch_history(
            key: required_argument(args, "key"),
            query: args["query"],
            endpoint: args["endpoint"]
          )
        else
          raise ArgumentError, "Unknown tool: #{name}"
        end
      end

      def required_argument(args, name)
        args.fetch(name) { raise ArgumentError, "Missing required argument: #{name}" }
      end

      def handle_resource_read(params)
        uri = params["uri"].to_s
        raise ArgumentError, "Missing required param: uri" if uri.empty?

        {
          "contents" => [
            {
              "uri" => uri,
              "mimeType" => "application/json",
              "text" => JSON.generate(read_resource(uri))
            }
          ]
        }
      end

      def read_resource(uri)
        case uri
        when "instant-record://status"
          @runtime.status
        when "instant-record://models"
          @runtime.list_models
        when "instant-record://outbox"
          @runtime.outbox
        when /\Ainstant-record:\/\/models\/(.+)\z/
          @runtime.query_records(model: Regexp.last_match(1))
        else
          raise ArgumentError, "Unknown resource URI: #{uri}"
        end
      end

      def tool_result(payload, is_error: false)
        {
          "content" => [{ "type" => "text", "text" => JSON.generate(payload) }],
          "isError" => is_error
        }
      end

      def result_response(id, result)
        { "jsonrpc" => JSONRPC_VERSION, "id" => id, "result" => result }
      end

      def error_response(id, code, message)
        { "jsonrpc" => JSONRPC_VERSION, "id" => id, "error" => { "code" => code, "message" => utf8(message) } }
      end

      def utf8(text) = String.new(text, encoding: Encoding::UTF_8).scrub

      def write_response(payload)
        @output.write("#{generate(payload)}\n")
        @output.flush
      end

      # An id such as 1e999 parses to a number JSON cannot write, and one nested
      # 100 deep is read but not written.
      def generate(payload)
        JSON.generate(payload)
      rescue JSON::GeneratorError, JSON::NestingError => e
        JSON.generate(error_response(nil, INTERNAL_ERROR, e.message))
      end
    end
  end
end
