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
        while (line = @input.gets)
          line = line.strip
          next if line.empty?

          response = handle_line(line)
          write_response(response) if response
        end
      end

      def handle_line(line)
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
          notification ? nil : error_response(id, METHOD_NOT_FOUND, "Method not found: #{method}")
        end
      rescue ArgumentError => e
        notification ? nil : error_response(id, INVALID_PARAMS, e.message)
      rescue StandardError => e
        @err&.puts("[instant_record:mcp] #{e.class}: #{e.message}")
        notification ? nil : error_response(id, INTERNAL_ERROR, e.message)
      end

      def tool_definitions
        [
          {
            "name" => "instant_record_status",
            "description" => "Inspect local SQLite replica sync cursor, pending outbox count, identity, models, and available screens (<1ms offline).",
            "inputSchema" => { "type" => "object", "properties" => {}, "additionalProperties" => false }
          },
          {
            "name" => "instant_record_sync",
            "description" => "Run a sync pass against the configured Rails server: push pending local outbox mutations and pull latest scoped changes.",
            "inputSchema" => {
              "type" => "object",
              "properties" => {
                "endpoint" => { "type" => "string", "description" => "Optional sync endpoint URL override." }
              },
              "additionalProperties" => false
            }
          },
          {
            "name" => "instant_record_models",
            "description" => "List all synced models in the local SQLite replica with table names, columns, row counts, and pending write counts (<1ms offline).",
            "inputSchema" => { "type" => "object", "properties" => {}, "additionalProperties" => false }
          },
          {
            "name" => "instant_record_query",
            "description" => "Query synced model records from the local SQLite replica with structured filters, sorting, column projection, and pagination (<1ms offline).",
            "inputSchema" => {
              "type" => "object",
              "properties" => {
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
                "columns" => {
                  "type" => "array",
                  "items" => { "type" => "string" },
                  "description" => "Optional subset of columns to return."
                },
                "limit" => { "type" => "integer", "minimum" => 1, "maximum" => 500, "default" => 50 },
                "offset" => { "type" => "integer", "minimum" => 0, "default" => 0 }
              },
              "required" => ["model"],
              "additionalProperties" => false
            }
          },
          {
            "name" => "instant_record_get",
            "description" => "Fetch a single synced record by model and primary key ID from the local SQLite replica (<1ms offline).",
            "inputSchema" => {
              "type" => "object",
              "properties" => {
                "model" => { "type" => "string", "description" => "Synced model or table name." },
                "id" => { "type" => "string", "description" => "Primary key value." }
              },
              "required" => %w[model id],
              "additionalProperties" => false
            }
          },
          {
            "name" => "instant_record_search",
            "description" => "Case-insensitive multi-term search across one or all synced models in the local SQLite replica (<1ms offline).",
            "inputSchema" => {
              "type" => "object",
              "properties" => {
                "query" => { "type" => "string", "description" => "Search query string (whitespace-separated terms must all match)." },
                "models" => {
                  "type" => "array",
                  "items" => { "type" => "string" },
                  "description" => "Optional list of models to restrict search to."
                },
                "columns" => {
                  "type" => "array",
                  "items" => { "type" => "string" },
                  "description" => "Optional list of columns to search (when restricting to models that share those columns)."
                },
                "limit" => { "type" => "integer", "minimum" => 1, "maximum" => 500, "default" => 50 }
              },
              "required" => ["query"],
              "additionalProperties" => false
            }
          },
          {
            "name" => "instant_record_outbox",
            "description" => "Inspect locally queued offline outbox mutations waiting to sync to the server (<1ms offline).",
            "inputSchema" => {
              "type" => "object",
              "properties" => {
                "limit" => { "type" => "integer", "minimum" => 1, "maximum" => 500, "default" => 100 }
              },
              "additionalProperties" => false
            }
          },
          {
            "name" => "instant_record_render_screen",
            "description" => "Render a compiled native screen (app/screens/*_screen.rb) from the local SQLite replica as structured JSON (<1ms offline).",
            "inputSchema" => {
              "type" => "object",
              "properties" => {
                "screen" => { "type" => "string", "description" => "Screen name (e.g. mailbox, thread)." },
                "params" => { "type" => "object", "description" => "Screen parameters (string key/value pairs)." }
              },
              "required" => ["screen"],
              "additionalProperties" => false
            }
          },
          {
            "name" => "instant_record_action",
            "description" => "Execute a validated local native screen action (Screen#perform) inside the compiled host offline, running validations and queueing outbox mutations (<1ms offline).",
            "inputSchema" => {
              "type" => "object",
              "properties" => {
                "screen" => { "type" => "string", "description" => "Screen name." },
                "action" => { "type" => "string", "description" => "Action name passed to Screen#perform." },
                "params" => { "type" => "object", "description" => "Screen parameters." },
                "args" => { "type" => "object", "description" => "Action arguments." },
                "values" => { "type" => "object", "description" => "Form field values." },
                "render" => { "type" => "boolean", "description" => "Re-render the screen after the action.", "default" => false },
                "sync" => { "type" => "boolean", "description" => "Run a sync pass immediately after the action.", "default" => false }
              },
              "required" => %w[screen action],
              "additionalProperties" => false
            }
          },
          {
            "name" => "instant_record_request",
            "description" => "Dispatch a validated local HTTP request (GET/POST/PATCH/DELETE) through the compiled Rails app inside the native host offline, running controller & model validations and queueing outbox mutations (<1ms offline).",
            "inputSchema" => {
              "type" => "object",
              "properties" => {
                "method" => { "type" => "string", "enum" => %w[GET POST PATCH PUT DELETE], "description" => "HTTP method." },
                "path" => { "type" => "string", "description" => "Application path (e.g. /todo/issues)." },
                "params" => { "type" => "object", "description" => "Request parameters (encoded as query string for GET, form or JSON for writes)." },
                "body" => { "type" => "string", "description" => "Optional raw request body." },
                "content_type" => { "type" => "string", "description" => "Optional Content-Type header." },
                "headers" => { "type" => "object", "description" => "Optional HTTP headers." },
                "sync" => { "type" => "boolean", "description" => "Run a sync pass after a successful request.", "default" => false }
              },
              "required" => %w[method path],
              "additionalProperties" => false
            }
          },
          {
            "name" => "instant_record_history",
            "description" => "Inspect local history pagination state or fetch an older keyset history page from the server into the local SQLite replica.",
            "inputSchema" => {
              "type" => "object",
              "properties" => {
                "key" => { "type" => "string", "description" => "History pagination key (e.g. older:support)." },
                "query" => { "type" => "string", "description" => "Optional /records query string to fetch from the server." },
                "endpoint" => { "type" => "string", "description" => "Optional sync endpoint override." }
              },
              "required" => ["key"],
              "additionalProperties" => false
            }
          }
        ]
      end

      def resource_definitions
        base = [
          {
            "uri" => "instant-record://status",
            "name" => "Replica Status",
            "description" => "Current sync cursor, pending outbox count, identity, and local SQLite replica metadata.",
            "mimeType" => "application/json"
          },
          {
            "uri" => "instant-record://models",
            "name" => "Synced Models",
            "description" => "Schema and row counts for every synced model in the local SQLite replica.",
            "mimeType" => "application/json"
          },
          {
            "uri" => "instant-record://outbox",
            "name" => "Pending Outbox Mutations",
            "description" => "Queued offline mutations waiting to sync to the Rails server.",
            "mimeType" => "application/json"
          }
        ]

        @runtime.list_models["models"].each do |model|
          base << {
            "uri" => "instant-record://models/#{model['name']}",
            "name" => "#{model['name']} Records",
            "description" => "Recent records of #{model['name']} (#{model['count']} local rows).",
            "mimeType" => "application/json"
          }
        end
        base
      end

      private

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
            model: args.fetch("model") { raise ArgumentError, "Missing required argument: model" },
            where: args["where"] || {},
            order: args["order"],
            limit: args["limit"] || Replica::DEFAULT_LIMIT,
            offset: args["offset"] || 0,
            columns: args["columns"]
          )
        when "instant_record_get"
          @runtime.get_record(
            model: args.fetch("model") { raise ArgumentError, "Missing required argument: model" },
            id: args.fetch("id") { raise ArgumentError, "Missing required argument: id" }
          )
        when "instant_record_search"
          @runtime.search_records(
            query: args.fetch("query") { raise ArgumentError, "Missing required argument: query" },
            models: args["models"],
            columns: args["columns"],
            limit: args["limit"] || Replica::DEFAULT_LIMIT
          )
        when "instant_record_outbox"
          @runtime.outbox(limit: args["limit"] || 100)
        when "instant_record_render_screen"
          @runtime.render_screen(
            screen: args.fetch("screen") { raise ArgumentError, "Missing required argument: screen" },
            params: args["params"] || {}
          )
        when "instant_record_action"
          @runtime.perform_action(
            screen: args.fetch("screen") { raise ArgumentError, "Missing required argument: screen" },
            action: args.fetch("action") { raise ArgumentError, "Missing required argument: action" },
            params: args["params"] || {},
            args: args["args"] || {},
            values: args["values"] || {},
            render: !!args["render"],
            sync: !!args["sync"]
          )
        when "instant_record_request"
          @runtime.app_request(
            method: args.fetch("method") { raise ArgumentError, "Missing required argument: method" },
            path: args.fetch("path") { raise ArgumentError, "Missing required argument: path" },
            params: args["params"],
            body: args["body"],
            headers: args["headers"] || {},
            content_type: args["content_type"],
            sync: !!args["sync"]
          )
        when "instant_record_history"
          @runtime.fetch_history(
            key: args.fetch("key") { raise ArgumentError, "Missing required argument: key" },
            query: args["query"],
            endpoint: args["endpoint"]
          )
        else
          raise ArgumentError, "Unknown tool: #{name}"
        end
      end

      def handle_resource_read(params)
        uri = params["uri"].to_s
        raise ArgumentError, "Missing required param: uri" if uri.empty?

        data =
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

        {
          "contents" => [
            {
              "uri" => uri,
              "mimeType" => "application/json",
              "text" => JSON.generate(data)
            }
          ]
        }
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
        { "jsonrpc" => JSONRPC_VERSION, "id" => id, "error" => { "code" => code, "message" => message } }
      end

      def write_response(payload)
        @output.write("#{JSON.generate(payload)}\n")
        @output.flush
      end
    end
  end
end
