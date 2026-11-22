require "json"
require "optparse"

module InstantRecord
  module Mcp
    # Offline CLI + drop-in MCP stdio server launcher around the compiled native
    # `host` binary. Invoked both by `bin/rails instant_record:mcp` and by the
    # standalone `instant_record_mcp` executable.
    class Cli
      SUBCOMMANDS = %w[serve sync status models query get search outbox render action request history].freeze

      def self.run(argv = ARGV, env: ENV, stdin: $stdin, stdout: $stdout, stderr: $stderr, defaults: {}, runtime_factory: nil)
        new(env: env, stdin: stdin, stdout: stdout, stderr: stderr, defaults: defaults, runtime_factory: runtime_factory).run(argv)
      end

      def initialize(env: ENV, stdin: $stdin, stdout: $stdout, stderr: $stderr, defaults: {}, runtime_factory: nil)
        @env = env
        @stdin = stdin
        @stdout = stdout
        @stderr = stderr
        @defaults = defaults
        @runtime_factory = runtime_factory
      end

      def run(argv)
        args = argv.dup
        options = default_options

        parser = build_global_parser(options)
        parser.order!(args)

        if options[:help]
          @stdout.puts(usage_text(parser))
          return 0
        end

        command = args.first && !args.first.start_with?("-") ? args.shift : "serve"
        unless SUBCOMMANDS.include?(command)
          @stderr.puts("Unknown command: #{command}. Available: #{SUBCOMMANDS.join(', ')}")
          return 2
        end

        cmd_options = {}
        cmd_parser = build_command_parser(command, cmd_options, options)
        cmd_parser.parse!(args)

        if options[:help]
          @stdout.puts(cmd_parser.to_s)
          return 0
        end

        runtime = build_runtime(options)
        begin
          if options[:sync_on_start] && command != "sync"
            sync_res = runtime.sync
            @stderr.puts("[instant_record:mcp] initial sync: #{sync_res['error'] || sync_res['summary']}")
          end

          execute_command(command, args, cmd_options, options, runtime)
        ensure
          runtime.close
        end
      rescue OptionParser::ParseError, ArgumentError => e
        @stderr.puts("Error: #{e.message}")
        2
      rescue Error => e
        @stderr.puts("Error: #{e.message}")
        1
      end

      private

      def default_options
        env_headers =
          if @env["INSTANT_RECORD_HEADERS"] && !@env["INSTANT_RECORD_HEADERS"].empty?
            JSON.parse(@env["INSTANT_RECORD_HEADERS"])
          else
            {}
          end

        scope = @env["INSTANT_RECORD_SCOPE"] || @defaults[:scope]
        root = @defaults[:root] || Dir.pwd

        {
          host: @env["INSTANT_RECORD_HOST"] || @defaults[:host] || Mcp.default_host_path(root),
          db: @env["INSTANT_RECORD_DB"] || @defaults[:db] || Mcp.default_database_path(root, scope: scope),
          endpoint: @env["INSTANT_RECORD_ENDPOINT"] || @defaults[:endpoint],
          token: @env["INSTANT_RECORD_TOKEN"] || @defaults[:token],
          cookie: @env["INSTANT_RECORD_COOKIE"] || @defaults[:cookie],
          scope: scope,
          headers: (@defaults[:headers] || {}).merge(env_headers),
          offline: truthy?(@env["INSTANT_RECORD_OFFLINE"]) || !!@defaults[:offline],
          sync_on_start: truthy?(@env["INSTANT_RECORD_SYNC_ON_START"]) || !!@defaults[:sync_on_start],
          build: truthy?(@env["INSTANT_RECORD_BUILD"]) || !!@defaults[:build],
          timeout: (@env["INSTANT_RECORD_TIMEOUT"] || @defaults[:timeout] || HttpExchange::DEFAULT_TIMEOUT).to_f,
          models: @defaults[:models],
          screens: @defaults[:screens] || [],
          pretty: false,
          help: false
        }
      end

      def build_global_parser(options)
        OptionParser.new do |opts|
          opts.banner = "Usage: instant_record_mcp [global options] [command] [command options]"
          opts.on("--host PATH", "Path to compiled native host binary") { |v| options[:host] = v }
          opts.on("--db PATH", "Path to local SQLite replica database") { |v| options[:db] = v }
          opts.on("--endpoint URL", "Rails sync endpoint URL") { |v| options[:endpoint] = v }
          opts.on("--token TOKEN", "Bearer auth token") { |v| options[:token] = v }
          opts.on("--cookie COOKIE", "Session Cookie header value") { |v| options[:cookie] = v }
          opts.on("--scope SCOPE", "Sync scope query parameter") { |v| options[:scope] = v }
          opts.on("--header HEADER", "Extra HTTP header ('Name: Value'), repeatable") do |v|
            name, value = v.split(":", 2)
            raise ArgumentError, "Header must be 'Name: Value'" if value.nil?

            options[:headers][name.strip] = value.strip
          end
          opts.on("--offline", "Disable network sync requests") { options[:offline] = true }
          opts.on("--sync-on-start", "Run a sync pass before executing or serving") { options[:sync_on_start] = true }
          opts.on("--timeout SECONDS", Float, "HTTP sync timeout in seconds") { |v| options[:timeout] = v }
          opts.on("--build", "Compile native host if missing (when build callback is available)") { options[:build] = true }
          opts.on("--pretty", "Pretty-print JSON output") { options[:pretty] = true }
          opts.on("-h", "--help", "Show help") { options[:help] = true }
        end
      end

      def build_command_parser(command, cmd_options, global_options)
        OptionParser.new do |opts|
          opts.banner = "Usage: instant_record_mcp #{command} [options]"
          case command
          when "query"
            cmd_options[:where] = {}
            opts.on("-w", "--where KEY=VALUE", "Filter condition (repeatable)") { |v| assign_kv(cmd_options[:where], v) }
            opts.on("--where-json JSON", "Filter object as JSON") { |v| cmd_options[:where].merge!(JSON.parse(v)) }
            opts.on("--order SPEC", "Sort order (e.g. 'created_at desc')") { |v| cmd_options[:order] = v }
            opts.on("--columns LIST", "Comma-separated column names") { |v| cmd_options[:columns] = v.split(",").map(&:strip) }
            opts.on("--limit N", Integer, "Max rows to return") { |v| cmd_options[:limit] = v }
            opts.on("--offset N", Integer, "Row offset") { |v| cmd_options[:offset] = v }
          when "search"
            cmd_options[:models] = []
            opts.on("-m", "--model NAME", "Restrict search to model (repeatable)") { |v| cmd_options[:models] << v }
            opts.on("--columns LIST", "Comma-separated columns to search") { |v| cmd_options[:columns] = v.split(",").map(&:strip) }
            opts.on("--limit N", Integer, "Max matches to return") { |v| cmd_options[:limit] = v }
          when "outbox"
            opts.on("--limit N", Integer, "Max outbox mutations to return") { |v| cmd_options[:limit] = v }
          when "render"
            cmd_options[:params] = {}
            opts.on("-p", "--param KEY=VALUE", "Screen param (repeatable)") { |v| assign_kv(cmd_options[:params], v) }
          when "action"
            cmd_options[:params] = {}
            cmd_options[:args] = {}
            cmd_options[:values] = {}
            opts.on("-p", "--param KEY=VALUE", "Screen param (repeatable)") { |v| assign_kv(cmd_options[:params], v) }
            opts.on("-a", "--arg KEY=VALUE", "Action arg (repeatable)") { |v| assign_kv(cmd_options[:args], v) }
            opts.on("-v", "--value KEY=VALUE", "Form field value (repeatable)") { |v| assign_kv(cmd_options[:values], v) }
            opts.on("--render", "Re-render the screen after performing the action") { cmd_options[:render] = true }
            opts.on("--sync", "Sync with the server after performing the action") { cmd_options[:sync] = true }
          when "request"
            cmd_options[:headers] = {}
            opts.on("-d", "--data BODY", "Raw request body") { |v| cmd_options[:body] = v }
            opts.on("--json JSON", "JSON object body (sets Content-Type: application/json)") do |v|
              cmd_options[:body] = JSON.generate(JSON.parse(v))
              cmd_options[:content_type] = "application/json"
            end
            opts.on("--content-type TYPE", "Content-Type header") { |v| cmd_options[:content_type] = v }
            opts.on("-H", "--header HEADER", "HTTP header ('Name: Value')") do |v|
              name, value = v.split(":", 2)
              raise ArgumentError, "Header must be 'Name: Value'" if value.nil?

              cmd_options[:headers][name.strip] = value.strip
            end
            opts.on("--sync", "Sync with the server after a successful request") { cmd_options[:sync] = true }
          when "history"
            opts.on("--query QUERY", "/records query string to fetch from the server") { |v| cmd_options[:query] = v }
          end

          opts.on("--pretty", "Pretty-print JSON output") { global_options[:pretty] = true }
          opts.on("-h", "--help", "Show help") { global_options[:help] = true }
        end
      end

      def build_runtime(options)
        return @runtime_factory.call(options) if @runtime_factory

        if !File.executable?(options[:host].to_s) && options[:build] && @defaults[:builder]
          built_dir = @defaults[:builder].call
          options[:host] = File.join(built_dir.to_s, "host")
        end

        Runtime.new(
          host_binary: options[:host],
          database_path: options[:db],
          endpoint: options[:endpoint],
          token: options[:token],
          cookie: options[:cookie],
          headers: options[:headers],
          scope: options[:scope],
          offline: options[:offline],
          timeout: options[:timeout],
          models: options[:models],
          screens: options[:screens],
          err: @stderr
        )
      end

      def execute_command(command, args, cmd_options, options, runtime)
        if command == "serve"
          Server.new(runtime, input: @stdin, output: @stdout, err: @stderr).run
          return 0
        end

        result =
          case command
          when "status"
            runtime.status
          when "sync"
            runtime.sync(endpoint: args.first)
          when "models"
            runtime.list_models
          when "query"
            model = args.shift or raise ArgumentError, "Usage: query <Model> [options]"
            runtime.query_records(
              model: model,
              where: cmd_options[:where] || {},
              order: cmd_options[:order],
              columns: cmd_options[:columns],
              limit: cmd_options[:limit] || Replica::DEFAULT_LIMIT,
              offset: cmd_options[:offset] || 0
            )
          when "get"
            model = args.shift
            id = args.shift
            raise ArgumentError, "Usage: get <Model> <id>" unless model && id

            runtime.get_record(model: model, id: id)
          when "search"
            query = args.join(" ").strip
            raise ArgumentError, "Usage: search <query> [options]" if query.empty?

            runtime.search_records(
              query: query,
              models: cmd_options[:models]&.empty? ? nil : cmd_options[:models],
              columns: cmd_options[:columns],
              limit: cmd_options[:limit] || Replica::DEFAULT_LIMIT
            )
          when "outbox"
            runtime.outbox(limit: cmd_options[:limit] || 100)
          when "render"
            screen = args.shift or raise ArgumentError, "Usage: render <screen> [--param k=v]"
            runtime.render_screen(screen: screen, params: cmd_options[:params] || {})
          when "action"
            screen = args.shift
            action = args.shift
            raise ArgumentError, "Usage: action <screen> <action> [--param k=v] [--arg k=v] [--value k=v]" unless screen && action

            runtime.perform_action(
              screen: screen,
              action: action,
              params: cmd_options[:params] || {},
              args: cmd_options[:args] || {},
              values: cmd_options[:values] || {},
              render: !!cmd_options[:render],
              sync: !!cmd_options[:sync]
            )
          when "request"
            method = args.shift
            path = args.shift
            raise ArgumentError, "Usage: request <METHOD> <path> [--data ...]" unless method && path

            runtime.app_request(
              method: method,
              path: path,
              body: cmd_options[:body],
              content_type: cmd_options[:content_type],
              headers: cmd_options[:headers] || {},
              sync: !!cmd_options[:sync]
            )
          when "history"
            key = args.shift or raise ArgumentError, "Usage: history <key> [--query ...]"
            runtime.fetch_history(key: key, query: cmd_options[:query])
          end

        json = options[:pretty] ? JSON.pretty_generate(result) : JSON.generate(result)
        @stdout.puts(json)
        result.is_a?(Hash) && result["ok"] == false ? 1 : 0
      end

      def assign_kv(hash, pair)
        key, value = pair.split("=", 2)
        raise ArgumentError, "Expected KEY=VALUE, got #{pair.inspect}" if value.nil? || key.empty?

        hash[key] = value
      end

      def truthy?(value)
        %w[1 true yes on].include?(value.to_s.strip.downcase)
      end

      def usage_text(parser)
        <<~TEXT
          #{parser}
          Commands (default: serve):
            serve                     Start MCP JSON-RPC 2.0 server over stdio
            sync [endpoint]           Push local outbox mutations and pull latest changes
            status                    Show sync cursor, pending count, models, and screens
            models                    List synced models and local row counts
            query <Model>             Query synced records from the local SQLite replica
            get <Model> <id>          Fetch a single synced record by ID
            search <query>            Search synced records across models
            outbox                    Inspect pending local offline mutations
            render <screen>           Render a compiled native screen as JSON
            action <screen> <action>  Perform a validated local screen action offline
            request <METHOD> <path>   Dispatch a validated local HTTP request offline
            history <key>             Inspect or fetch a windowed history page
        TEXT
      end
    end
  end
end
