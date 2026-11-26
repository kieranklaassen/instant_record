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

        cmd_parser = OptionParser.new("Usage: instant_record_mcp #{command} [options]")
        call = define_command(command, cmd_parser)
        cmd_parser.on("--pretty", "Pretty-print JSON output") { options[:pretty] = true }
        cmd_parser.on("-h", "--help", "Show help") { options[:help] = true }
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

          if command == "serve"
            Server.new(runtime, input: @stdin, output: @stdout, err: @stderr).run
            return 0
          end

          print_result(call.call(runtime, args), pretty: options[:pretty])
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
        headers = @env["INSTANT_RECORD_HEADERS"].to_s
        env_headers = headers.empty? ? {} : json_object("INSTANT_RECORD_HEADERS", headers)
        scope = setting("INSTANT_RECORD_SCOPE", :scope)
        root = @defaults[:root] || Dir.pwd

        {
          host: setting("INSTANT_RECORD_HOST", :host) || Mcp.default_host_path(root),
          db: setting("INSTANT_RECORD_DB", :db) || Mcp.default_database_path(root, scope: scope),
          endpoint: setting("INSTANT_RECORD_ENDPOINT", :endpoint),
          token: setting("INSTANT_RECORD_TOKEN", :token),
          cookie: setting("INSTANT_RECORD_COOKIE", :cookie),
          scope: scope,
          headers: (@defaults[:headers] || {}).merge(env_headers),
          offline: flag("INSTANT_RECORD_OFFLINE", :offline),
          sync_on_start: flag("INSTANT_RECORD_SYNC_ON_START", :sync_on_start),
          build: flag("INSTANT_RECORD_BUILD", :build),
          timeout: (setting("INSTANT_RECORD_TIMEOUT", :timeout) || HttpExchange::DEFAULT_TIMEOUT).to_f,
          models: @defaults[:models],
          screens: @defaults[:screens] || [],
          pretty: false,
          help: false
        }
      end

      def setting(variable, key)
        @env[variable] || @defaults[key]
      end

      def flag(variable, key)
        truthy?(@env[variable]) || !!@defaults[key]
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
          opts.on("--header HEADER", "Extra HTTP header ('Name: Value'), repeatable") { |v| assign_header(options[:headers], v) }
          opts.on("--offline", "Disable network sync requests") { options[:offline] = true }
          opts.on("--sync-on-start", "Run a sync pass before executing or serving") { options[:sync_on_start] = true }
          opts.on("--timeout SECONDS", Float, "HTTP sync timeout in seconds") { |v| options[:timeout] = v }
          opts.on("--build", "Compile native host if missing (when build callback is available)") { options[:build] = true }
          opts.on("--pretty", "Pretty-print JSON output") { options[:pretty] = true }
          opts.on("-h", "--help", "Show help") { options[:help] = true }
        end
      end

      # Adds the command's options to `opts` and returns the call it makes, to run
      # once they are parsed.
      def define_command(command, opts)
        case command
        when "sync" then ->(runtime, args) { runtime.sync(endpoint: args.first) }
        when "status" then ->(runtime, _args) { runtime.status }
        when "models" then ->(runtime, _args) { runtime.list_models }
        when "query" then define_query(opts)
        when "get" then define_get
        when "search" then define_search(opts)
        when "outbox" then define_outbox(opts)
        when "render" then define_render(opts)
        when "action" then define_action(opts)
        when "request" then define_request(opts)
        when "history" then define_history(opts)
        end
      end

      def define_query(opts)
        where = {}
        options = { order: nil, columns: nil, limit: Replica::DEFAULT_LIMIT, offset: 0 }
        opts.on("-w", "--where KEY=VALUE", "Filter condition (repeatable)") { |v| assign_kv(where, v) }
        opts.on("--where-json JSON", "Filter object as JSON") { |v| where.merge!(json_object("--where-json", v)) }
        opts.on("--order SPEC", "Sort order (e.g. 'created_at desc')") { |v| options[:order] = v }
        opts.on("--columns LIST", "Comma-separated column names") { |v| options[:columns] = split_list(v) }
        opts.on("--limit N", Integer, "Max rows to return") { |v| options[:limit] = v }
        opts.on("--offset N", Integer, "Row offset") { |v| options[:offset] = v }

        lambda do |runtime, args|
          model = args.first or raise ArgumentError, "Usage: query <Model> [options]"
          runtime.query_records(model: model, where: where, **options)
        end
      end

      def define_get
        lambda do |runtime, args|
          model, id = args
          raise ArgumentError, "Usage: get <Model> <id>" unless model && id

          runtime.get_record(model: model, id: id)
        end
      end

      def define_search(opts)
        models = []
        options = { columns: nil, limit: Replica::DEFAULT_LIMIT }
        opts.on("-m", "--model NAME", "Restrict search to model (repeatable)") { |v| models << v }
        opts.on("--columns LIST", "Comma-separated columns to search") { |v| options[:columns] = split_list(v) }
        opts.on("--limit N", Integer, "Max matches to return") { |v| options[:limit] = v }

        lambda do |runtime, args|
          query = args.join(" ").strip
          raise ArgumentError, "Usage: search <query> [options]" if query.empty?

          runtime.search_records(query: query, models: models.empty? ? nil : models, **options)
        end
      end

      def define_outbox(opts)
        limit = 100
        opts.on("--limit N", Integer, "Max outbox mutations to return") { |v| limit = v }

        ->(runtime, _args) { runtime.outbox(limit: limit) }
      end

      def define_render(opts)
        params = {}
        opts.on("-p", "--param KEY=VALUE", "Screen param (repeatable)") { |v| assign_kv(params, v) }

        lambda do |runtime, args|
          screen = args.first or raise ArgumentError, "Usage: render <screen> [--param k=v]"
          runtime.render_screen(screen: screen, params: params)
        end
      end

      def define_action(opts)
        options = { params: {}, args: {}, values: {}, render: false, sync: false }
        opts.on("-p", "--param KEY=VALUE", "Screen param (repeatable)") { |v| assign_kv(options[:params], v) }
        opts.on("-a", "--arg KEY=VALUE", "Action arg (repeatable)") { |v| assign_kv(options[:args], v) }
        opts.on("-v", "--value KEY=VALUE", "Form field value (repeatable)") { |v| assign_kv(options[:values], v) }
        opts.on("--render", "Re-render the screen after performing the action") { options[:render] = true }
        opts.on("--sync", "Sync with the server after performing the action") { options[:sync] = true }

        lambda do |runtime, args|
          screen, action = args
          raise ArgumentError, "Usage: action <screen> <action> [--param k=v] [--arg k=v] [--value k=v]" unless screen && action

          runtime.perform_action(screen: screen, action: action, **options)
        end
      end

      def define_request(opts)
        options = { body: nil, content_type: nil, headers: {}, sync: false }
        opts.on("-d", "--data BODY", "Raw request body") { |v| options[:body] = v }
        opts.on("--json JSON", "JSON object body (sets Content-Type: application/json)") do |v|
          options[:body] = valid_json("--json") { JSON.generate(JSON.parse(v)) }
          options[:content_type] = "application/json"
        end
        opts.on("--content-type TYPE", "Content-Type header") { |v| options[:content_type] = v }
        opts.on("-H", "--header HEADER", "HTTP header ('Name: Value')") { |v| assign_header(options[:headers], v) }
        opts.on("--sync", "Sync with the server after a successful request") { options[:sync] = true }

        lambda do |runtime, args|
          method, path = args
          raise ArgumentError, "Usage: request <METHOD> <path> [--data ...]" unless method && path

          runtime.app_request(method: method, path: path, **options)
        end
      end

      def define_history(opts)
        query = nil
        opts.on("--query QUERY", "/records query string to fetch from the server") { |v| query = v }

        lambda do |runtime, args|
          key = args.first or raise ArgumentError, "Usage: history <key> [--query ...]"
          runtime.fetch_history(key: key, query: query)
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

      def print_result(result, pretty:)
        @stdout.puts(pretty ? JSON.pretty_generate(result) : JSON.generate(result))
        result.is_a?(Hash) && result["ok"] == false ? 1 : 0
      end

      def assign_kv(hash, pair)
        key, value = pair.split("=", 2)
        raise ArgumentError, "Expected KEY=VALUE, got #{pair.inspect}" if value.nil? || key.empty?

        hash[key] = value
      end

      def assign_header(headers, line)
        name, value = line.split(":", 2)
        raise ArgumentError, "Header must be 'Name: Value'" if value.nil?

        headers[name.strip] = value.strip
      end

      def json_object(name, text)
        value = valid_json(name) { JSON.parse(text) }
        raise ArgumentError, "Expected a JSON object for #{name}" unless value.is_a?(Hash)

        value
      end

      # The parser's message can quote the input, which may hold credentials.
      def valid_json(name)
        yield
      rescue JSON::JSONError
        raise ArgumentError, "Expected valid JSON for #{name}"
      end

      def split_list(list)
        list.split(",").map(&:strip)
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
