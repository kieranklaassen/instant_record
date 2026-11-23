# Generate SQLite DDL with Rails' adapter. Read migration syntax without
# executing application Ruby or touching ActiveRecord::Base.connection.
require "active_record"
require "active_record/connection_adapters/sqlite3_adapter"
require "digest"
require "json"
require "pathname"
require "prism"
require_relative "runner"

module InstantRecord
  class Compiler
    class BrowserMigrations
      def self.schema_ddl(root:, migration_paths: nil)
        planned = plan(root: root, baseline: nil, migration_paths: migration_paths)
        statements = planned.fetch("migrations").sort_by { |version, _| version.to_i }.flat_map(&:last)
        { version: planned["version"], statements: statements }
      end

      def self.plan(root:, baseline: nil, migration_paths: nil, only_files: nil)
        schema_path = File.join(root, "db/schema.rb")
        raise BuildError, "Missing #{schema_path}" unless File.file?(schema_path)

        schema = File.read(schema_path)
        version_match = schema.match(/\.define\s*\(\s*version:\s*([\d_]+)/)
        raise BuildError, "Missing db/schema.rb version" unless version_match

        version = Integer(version_match[1], 10)
        baseline_int = baseline.nil? || baseline.to_s.empty? ? nil : Integer(baseline.to_s, 10)
        raise BuildError, "Invalid browser migration baseline" if baseline_int && !(0..version).cover?(baseline_int)

        paths =
          if only_files
            Array(only_files).map { |f| Pathname(f).absolute? ? f.to_s : File.join(root, f.to_s) }
              .select { |file| File.file?(file) }
              .uniq
              .sort_by { |file| File.basename(file).to_i }
          else
            dirs = Array(migration_paths || [File.join(root, "db/migrate")])
            dirs.flat_map { |dir| File.directory?(dir) ? Dir.glob("[0-9]*_*.rb", base: dir).map { |name| File.join(dir, name) } : [] }
              .uniq
              .sort_by { |file| File.basename(file).to_i }
          end

        connection = ActiveRecord::ConnectionAdapters::SQLite3Adapter.new({ adapter: "sqlite3", database: ":memory:" })
        compiler = new(connection)
        migrations = {}

        paths.each do |file|
          number = File.basename(file).to_i
          raise BuildError, "Run db:migrate and dump the schema before compiling #{file}" if number > version
          next if baseline_int && number <= baseline_int
          raise BuildError, "Duplicate browser migration version #{number}" if migrations.key?(number.to_s)

          companion = File.join(root, "db/browser_migrate", File.basename(file, ".rb") + ".sql")
          begin
            migrations[number.to_s] = File.file?(companion) ? [File.read(companion)] : compiler.compile(file)
          rescue StandardError => e
            raise BuildError, "#{file}: #{e.message}. Supply portable SQLite SQL in #{companion}."
          end
        end

        history = migrations.transform_values { |statements| Digest::SHA256.hexdigest(JSON.generate(statements)) }
        { "version" => version, "baseline" => baseline_int, "migrations" => migrations, "history" => history }
      ensure
        connection&.disconnect!
      end

      def initialize(connection)
        @connection = connection
        @visitor = connection.schema_creation
      end

      def compile(path)
        parsed = Prism.parse_file(path)
        nodes = parsed.value.statements.body
        klass = nodes.first
        raise "expected one migration class" unless parsed.success? && nodes.one? && klass.is_a?(Prism::ClassNode)

        methods = klass.body&.body || []
        unless methods.all? { |m| m.is_a?(Prism::DefNode) && m.receiver.nil? && %i[change up down].include?(m.name) }
          raise "custom migration methods or class-level code"
        end

        up = methods.select { |m| %i[change up].include?(m.name) }
        raise "expected change or up" unless up.one?

        Array(up.first.body&.body).flat_map { |command| statements(command) }
      end

      private

      def literal(node)
        case node
        when Prism::SymbolNode then node.unescaped.to_sym
        when Prism::StringNode then node.unescaped
        when Prism::IntegerNode, Prism::FloatNode then node.value
        when Prism::TrueNode then true
        when Prism::FalseNode then false
        when Prism::NilNode then nil
        when Prism::ArrayNode then node.elements.map { |item| literal(item) }
        else raise "dynamic migration argument at line #{node.location.start_line}"
        end
      end

      def arguments(call)
        args = Array(call.arguments&.arguments).dup
        options = {}
        if args.last.is_a?(Prism::KeywordHashNode)
          args.pop.elements.each do |pair|
            raise "dynamic migration options" unless pair.is_a?(Prism::AssocNode)

            options[literal(pair.key)] = literal(pair.value)
          end
        end
        [args.map { |arg| literal(arg) }, options]
      end

      def statements(call)
        raise "expected a Rails migration operation" unless call.is_a?(Prism::CallNode) && call.receiver.nil?

        args, options = arguments(call)
        raise "conditional or destructive DDL" if options.keys.intersect?([:force, :if_exists, :if_not_exists])
        raise "unexpected migration block" if call.block && call.name != :create_table

        case call.name
        when :add_column
          [@visitor.accept(@connection.build_add_column_definition(*args, **options))]
        when :add_index
          [index_sql(*args, **options)]
        when :execute
          raise "expected one literal SQL string" unless args.one? && args.first.is_a?(String) && options.empty?

          args
        when :create_table
          definition = @connection.build_create_table_definition(*args, **options)
          if (block = call.block)
            name = block.parameters&.parameters&.requireds&.first&.name
            Array(block.body&.body).each do |column|
              unless column.is_a?(Prism::CallNode) && column.receiver.is_a?(Prism::LocalVariableReadNode) &&
                  column.receiver.name == name && !column.block &&
                  (@connection.native_database_types.key?(column.name) || %i[column timestamps index].include?(column.name))
                raise "unsupported create_table declaration"
              end

              values, keywords = arguments(column)
              definition.public_send(column.name, *values, **keywords)
            end
          end
          [@visitor.accept(definition), *definition.indexes.map { |columns, opts| index_sql(args.first, columns, **opts) }]
        else
          raise "unsupported operation #{call.name}"
        end
      end

      def index_sql(*args, **options)
        @visitor.accept(@connection.build_create_index_definition(*args, **options))
      end
    end
  end
end
