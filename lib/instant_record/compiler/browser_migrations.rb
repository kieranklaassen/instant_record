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
      NATIVE_DATABASE_TYPES = ActiveRecord::ConnectionAdapters::SQLite3Adapter::NATIVE_DATABASE_TYPES
      PRIMARY_KEY_SQL = NATIVE_DATABASE_TYPES.fetch(:primary_key).freeze
      SQLITE_TYPE_NAMES = NATIVE_DATABASE_TYPES.each_with_object({}) do |(type, spec), map|
        map[type] = (spec.is_a?(Hash) ? spec[:name] : spec).freeze
      end.freeze
      ALLOWED_TABLE_DECLARATIONS = (NATIVE_DATABASE_TYPES.keys + %i[column timestamps index]).each_with_object({}) do |name, map|
        map[name] = true
      end.freeze
      FAST_CREATE_TABLE_OPTS = { id: true, primary_key: true }.freeze
      FAST_COLUMN_OPTS = { null: true, default: true, primary_key: true, precision: true, scale: true, limit: true, index: true }.freeze
      FAST_ADD_COLUMN_OPTS = { null: true, default: true, precision: true, scale: true, limit: true }.freeze
      FAST_TIMESTAMPS_OPTS = { null: true, precision: true }.freeze
      FAST_INDEX_OPTS = { unique: true, name: true, where: true }.freeze
      DESTRUCTIVE_DDL_OPTS = %i[force if_exists if_not_exists].freeze
      SIMPLE_IDENTIFIER = /\A\w+\z/
      MIGRATION_FILE_PATTERN = /\A[0-9][^\/]*_[^\/]*\.rb\z/
      SCHEMA_VERSION_PATTERN = /\.define\s*\(\s*version:\s*([\d_]+)/
      SCHEMA_HEAD_BYTES = 4096
      MAX_INDEX_NAME_BYTES = 62
      MAX_CACHE_ENTRIES = 512
      EMPTY_ARGS = [].freeze
      EMPTY_OPTS = {}.freeze
      DEFAULT_TIMESTAMPS_OPTS = { null: false }.freeze
      CACHE_MUTEX = Mutex.new
      COMPILE_CACHE = {}

      def self.schema_ddl(root:, migration_paths: nil)
        planned = plan(root: root, baseline: nil, migration_paths: migration_paths)
        statements = planned.fetch("migrations").sort_by { |version, _| version.to_i }.flat_map(&:last)
        { version: planned["version"], statements: statements }
      end

      def self.plan(root:, baseline: nil, migration_paths: nil, only_files: nil)
        schema_path = File.join(root, "db/schema.rb")
        raise BuildError, "Missing #{schema_path}" unless File.file?(schema_path)

        schema_head = File.read(schema_path, SCHEMA_HEAD_BYTES)
        version_match = schema_head&.match(SCHEMA_VERSION_PATTERN)
        if (version_match.nil? || version_match.end(0) >= schema_head.bytesize) &&
            schema_head && schema_head.bytesize >= SCHEMA_HEAD_BYTES
          version_match = File.read(schema_path).match(SCHEMA_VERSION_PATTERN)
        end
        raise BuildError, "Missing db/schema.rb version" unless version_match

        version = Integer(version_match[1], 10)
        baseline_int = baseline.nil? || baseline.to_s.empty? ? nil : Integer(baseline.to_s, 10)
        raise BuildError, "Invalid browser migration baseline" if baseline_int && !(0..version).cover?(baseline_int)

        entries = collect_migration_entries(root, migration_paths, only_files)

        compiler = new
        migrations = {}
        history = {}
        browser_migrate_dir = File.join(root, "db/browser_migrate")
        companion_entries =
          if File.directory?(browser_migrate_dir)
            Dir.children(browser_migrate_dir).each_with_object({}) { |name, map| map[name] = true }
          end

        entries.each do |number, file, base|
          raise BuildError, "Run db:migrate and dump the schema before compiling #{file}" if number > version
          next if baseline_int && number <= baseline_int
          number_key = number.to_s
          raise BuildError, "Duplicate browser migration version #{number}" if migrations.key?(number_key)

          begin
            if companion_entries && (sql_name = "#{base.delete_suffix('.rb')}.sql") &&
                companion_entries.key?(sql_name) && File.file?(companion_path = File.join(browser_migrate_dir, sql_name))
              stmts = [File.read(companion_path)]
              migrations[number_key] = stmts
              history[number_key] = Digest::SHA256.hexdigest(JSON.generate(stmts))
            else
              stmts, digest = compiler.compile_with_digest(file)
              migrations[number_key] = stmts
              history[number_key] = digest
            end
          rescue StandardError => e
            companion = File.join(browser_migrate_dir, "#{base.delete_suffix('.rb')}.sql")
            raise BuildError, "#{file}: #{e.message}. Supply portable SQLite SQL in #{companion}."
          end
        end

        { "version" => version, "baseline" => baseline_int, "migrations" => migrations, "history" => history }
      ensure
        compiler&.disconnect!
      end

      def self.collect_migration_entries(root, migration_paths, only_files)
        seen = {}
        entries = []
        if only_files
          Array(only_files).each do |f|
            raw = f.to_s
            file = File.absolute_path?(raw) ? raw : File.join(root, raw)
            next if seen.key?(file) || !File.file?(file)

            seen[file] = true
            base = File.basename(file)
            entries << [base.to_i, file, base]
          end
        else
          dirs = Array(migration_paths || [File.join(root, "db/migrate")])
          dirs.each do |dir|
            next unless File.directory?(dir)

            Dir.children(dir).each do |name|
              next unless MIGRATION_FILE_PATTERN.match?(name)

              file = File.join(dir, name)
              next if seen.key?(file)

              seen[file] = true
              entries << [name.to_i, file, name]
            end
          end
        end
        entries.sort_by!(&:first)
        entries
      end
      private_class_method :collect_migration_entries

      def initialize(connection = nil)
        @explicit_connection = !connection.nil?
        @connection = connection
        @visitor = connection&.schema_creation
      end

      def disconnect!
        return if @explicit_connection || @connection.nil?

        @connection.disconnect!
        @connection = nil
        @visitor = nil
      end

      def compile(path)
        compile_source(File.binread(path))
      end

      def compile_with_digest(path)
        source = File.binread(path)
        unless fast_sqlite?
          stmts = compile_source(source)
          return [stmts, Digest::SHA256.hexdigest(JSON.generate(stmts))]
        end

        if (cached = CACHE_MUTEX.synchronize { COMPILE_CACHE[source] })
          return [cached[0].dup, cached[1]]
        end

        stmts = compile_source(source)
        frozen_stmts = stmts.map(&:freeze).freeze
        digest = Digest::SHA256.hexdigest(JSON.generate(frozen_stmts)).freeze
        entry = [frozen_stmts, digest].freeze
        CACHE_MUTEX.synchronize do
          COMPILE_CACHE.shift if COMPILE_CACHE.size >= MAX_CACHE_ENTRIES && !COMPILE_CACHE.key?(source)
          COMPILE_CACHE[source.freeze] = entry
        end
        [frozen_stmts.dup, digest]
      end

      private

      def compile_source(source)
        parsed = Prism.parse(source)
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

      def fallback_connection
        @connection ||= ActiveRecord::ConnectionAdapters::SQLite3Adapter.new({ adapter: "sqlite3", database: ":memory:" })
      end

      def fallback_visitor
        @visitor ||= fallback_connection.schema_creation
      end

      def fast_sqlite?
        !@explicit_connection && (ActiveRecord.autoload?(:Base) || ActiveRecord::Base.primary_key_prefix_type.nil?)
      end

      def allowed_table_declaration?(name)
        if @explicit_connection
          @connection.native_database_types.key?(name) || name == :column || name == :timestamps || name == :index
        else
          ALLOWED_TABLE_DECLARATIONS.key?(name)
        end
      end

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
        raw_args = call.arguments&.arguments
        return [EMPTY_ARGS, EMPTY_OPTS] if raw_args.nil? || raw_args.empty?

        last = raw_args.last
        if last.is_a?(Prism::KeywordHashNode)
          options = {}
          last.elements.each do |pair|
            raise "dynamic migration options" unless pair.is_a?(Prism::AssocNode)

            options[literal(pair.key)] = literal(pair.value)
          end
          count = raw_args.length - 1
          args = count == 0 ? EMPTY_ARGS : Array.new(count) { |i| literal(raw_args[i]) }
          [args, options]
        else
          [raw_args.map { |arg| literal(arg) }, EMPTY_OPTS]
        end
      end

      def statements(call)
        raise "expected a Rails migration operation" unless call.is_a?(Prism::CallNode) && call.receiver.nil?

        args, options = arguments(call)
        if DESTRUCTIVE_DDL_OPTS.any? { |key| options.key?(key) }
          raise "conditional or destructive DDL"
        end
        raise "unexpected migration block" if call.block && call.name != :create_table

        case call.name
        when :add_column
          if fast_sqlite? && (fast = fast_add_column(args, options))
            return fast
          end
          [fallback_visitor.accept(fallback_connection.build_add_column_definition(*args, **options))]
        when :add_index
          if fast_sqlite? && args.size == 2 && (fast = fast_index_sql(args[0], args[1], options))
            return [fast]
          end
          [index_sql(*args, **options)]
        when :execute
          raise "expected one literal SQL string" unless args.one? && args.first.is_a?(String) && options.empty?

          args
        when :create_table
          decls = nil
          if (block = call.block)
            name = block.parameters&.parameters&.requireds&.first&.name
            decls = Array(block.body&.body).map do |column|
              unless column.is_a?(Prism::CallNode) && column.receiver.is_a?(Prism::LocalVariableReadNode) &&
                  column.receiver.name == name && !column.block && allowed_table_declaration?(column.name)
                raise "unsupported create_table declaration"
              end

              [column.name, *arguments(column)]
            end
          end

          if fast_sqlite? && (fast = fast_create_table(args, options, decls))
            return fast
          end

          definition = fallback_connection.build_create_table_definition(*args, **options)
          decls&.each do |method_name, values, keywords|
            definition.public_send(method_name, *values, **keywords)
          end
          [fallback_visitor.accept(definition), *definition.indexes.map { |columns, opts| index_sql(args.first, columns, **opts) }]
        else
          raise "unsupported operation #{call.name}"
        end
      end

      def index_sql(*args, **options)
        fallback_visitor.accept(fallback_connection.build_create_index_definition(*args, **options))
      end

      def quote_column_name(name)
        s = name.to_s
        s.include?('"') ? %("#{s.gsub('"', '""')}") : %("#{s}")
      end

      def quote_table_name(name)
        s = name.to_s
        if s.include?('"') || s.include?(".")
          %("#{s.gsub('"', '""').gsub('.', '"."')}")
        else
          %("#{s}")
        end
      end

      def quote_sqlite_string(str)
        str.include?("'") ? "'#{str.gsub("'", "''")}'" : "'#{str}'"
      end

      def format_sql_type(type, options)
        type = :datetime if type == :timestamp
        return PRIMARY_KEY_SQL if type == :primary_key
        return nil if type == :virtual

        base = SQLITE_TYPE_NAMES[type]
        return type.to_s unless base

        case type
        when :decimal
          precision = options[:precision]
          scale = options[:scale]
          if precision
            return nil unless precision.is_a?(Integer)

            if scale
              return nil unless scale.is_a?(Integer)

              "#{base}(#{precision},#{scale})"
            else
              "#{base}(#{precision})"
            end
          elsif scale
            nil
          else
            base
          end
        when :datetime, :time
          precision = options.key?(:precision) ? options[:precision] : (type == :datetime ? 6 : nil)
          if precision.nil?
            if (limit = options[:limit])
              return nil unless limit.is_a?(Integer)

              "#{base}(#{limit})"
            else
              base
            end
          elsif precision.is_a?(Integer) && precision >= 0 && precision <= 6
            "#{base}(#{precision})"
          end
        else
          if (limit = options[:limit])
            return nil unless limit.is_a?(Integer)

            "#{base}(#{limit})"
          else
            base
          end
        end
      end

      def format_default_value(type, default, limit: nil)
        return "NULL" if default.nil?

        case type
        when :string, :text
          return nil unless default.is_a?(String) && default.encoding != Encoding::ASCII_8BIT

          quote_sqlite_string(default)
        when :integer
          return nil unless default.is_a?(Integer)

          effective_limit = limit.nil? ? 8 : limit
          return nil unless effective_limit.is_a?(Integer) && effective_limit >= 1 && effective_limit <= 8

          bound = 1 << (effective_limit * 8 - 1)
          (default >= -bound && default < bound) ? default.to_s : nil
        when :float
          if default.is_a?(Integer) || (default.is_a?(Float) && default.finite?)
            f = default.to_f
            f.finite? ? f.to_s : nil
          end
        when :boolean
          if default == true
            "TRUE"
          elsif default == false
            "FALSE"
          end
        end
      end

      def format_column_def(name, type, options, for_create_table:)
        return nil unless name.is_a?(Symbol) || name.is_a?(String)

        if for_create_table
          if options.key?(:primary_key) && !(options[:primary_key] == true || options[:primary_key] == false || options[:primary_key].nil?)
            return nil
          end

          if options[:primary_key] == true && (type == :integer || type == :bigint) && !options.key?(:default)
            type = :primary_key
          end
          type = :datetime if type == :timestamp
          is_pk = options[:primary_key] == true || type == :primary_key
          effective_null = is_pk ? false : options[:null]
        else
          type = :datetime if type == :timestamp
          effective_null = options[:null]
        end

        sql_type = format_sql_type(type, options)
        return nil unless sql_type

        sql = +"#{quote_column_name(name)} #{sql_type}"
        unless type == :primary_key
          if options.key?(:default) && !(effective_null == false && options[:default].nil?)
            dval = format_default_value(type, options[:default], limit: options[:limit])
            return nil unless dval

            sql << " DEFAULT " << dval
          end
          sql << " NOT NULL" if effective_null == false
          sql << " PRIMARY KEY" if for_create_table && options[:primary_key] == true
        end
        sql
      end

      def fast_add_column(args, options)
        return nil unless args.size == 3

        table, col, type = args
        return nil unless (table.is_a?(Symbol) || table.is_a?(String)) &&
          (col.is_a?(Symbol) || col.is_a?(String)) &&
          (type.is_a?(Symbol) || type.is_a?(String))
        return nil unless options.each_key.all? { |k| FAST_ADD_COLUMN_OPTS.key?(k) }

        col_sql = format_column_def(col, type.to_sym, options, for_create_table: false)
        return nil unless col_sql

        ["ALTER TABLE #{quote_table_name(table)} ADD #{col_sql}"]
      end

      def fast_index_sql(table, columns, options)
        return nil unless table.is_a?(Symbol) || table.is_a?(String)
        return nil unless options.each_key.all? { |k| FAST_INDEX_OPTS.key?(k) }

        col_list =
          case columns
          when Symbol
            [columns.to_s]
          when String
            return nil unless SIMPLE_IDENTIFIER.match?(columns)

            [columns]
          when Array
            return nil if columns.empty?

            list = columns.map do |c|
              case c
              when Symbol then c.to_s
              when String
                return nil unless SIMPLE_IDENTIFIER.match?(c)

                c
              else
                return nil
              end
            end
            return nil if list.uniq.size != list.size

            list
          else
            return nil
          end

        if options.key?(:name) && !(options[:name].nil? || options[:name].is_a?(String) || options[:name].is_a?(Symbol))
          return nil
        end

        idx_name =
          if (custom = options[:name])
            custom.to_s
          else
            generated = "index_#{table}_on_#{col_list.join('_and_')}"
            if generated.bytesize <= MAX_INDEX_NAME_BYTES
              generated
            else
              short = "idx_on_#{col_list.join('_')}"
              return nil unless short.ascii_only?

              "#{short.byteslice(0, MAX_INDEX_NAME_BYTES - 11)}_#{Digest::SHA256.hexdigest(generated)[0, 10]}"
            end
          end
        return nil if idx_name.bytesize > MAX_INDEX_NAME_BYTES

        where = options[:where]
        return nil unless where.nil? || where.is_a?(String)

        sql = options[:unique] ? +"CREATE UNIQUE INDEX " : +"CREATE INDEX "
        sql << quote_column_name(idx_name) << " ON " << quote_table_name(table) << " ("
        col_list.each_with_index do |c, i|
          sql << ", " if i > 0
          sql << quote_column_name(c)
        end
        sql << ")"
        sql << " WHERE " << where if where
        sql
      end

      def fast_create_table(args, options, decls)
        return nil unless args.size == 1 && (args[0].is_a?(Symbol) || args[0].is_a?(String))
        return nil unless options.each_key.all? { |k| FAST_CREATE_TABLE_OPTS.key?(k) }

        table = args[0]
        id = options.key?(:id) ? options[:id] : :primary_key
        pk = options[:primary_key]
        return nil unless pk.nil? || pk.is_a?(Symbol) || pk.is_a?(String)

        col_sqls = []
        seen_cols = {}
        inline_indexes = []

        if id
          pk_name = (pk || "id").to_s
          case id
          when :primary_key, :integer, :bigint
            seen_cols[pk_name] = true
            col_sqls << "#{quote_column_name(pk_name)} #{PRIMARY_KEY_SQL}"
          when :string
            seen_cols[pk_name] = true
            col_sqls << "#{quote_column_name(pk_name)} varchar NOT NULL PRIMARY KEY"
          else
            return nil
          end
        elsif id != false && !id.nil?
          return nil
        end

        decls&.each do |method_name, values, keywords|
          case method_name
          when :timestamps
            return nil unless values.empty? && keywords.each_key.all? { |k| FAST_TIMESTAMPS_OPTS.key?(k) }

            ts_opts =
              if keywords.empty?
                DEFAULT_TIMESTAMPS_OPTS
              elsif keywords[:null].nil?
                keywords.merge(null: false)
              else
                keywords
              end
            %w[created_at updated_at].each do |ts_col|
              return nil if seen_cols[ts_col]

              seen_cols[ts_col] = true
              csql = format_column_def(ts_col, :datetime, ts_opts, for_create_table: true)
              return nil unless csql

              col_sqls << csql
            end
          when :index
            return nil unless values.size == 1

            inline_indexes << [values[0], keywords]
          when :column
            return nil unless values.size == 2 && keywords.each_key.all? { |k| FAST_COLUMN_OPTS.key?(k) }

            cname, ctype = values
            return nil unless ctype.is_a?(Symbol) || ctype.is_a?(String)
            return nil unless append_fast_column(col_sqls, seen_cols, inline_indexes, cname, ctype.to_sym, keywords)
          when :primary_key
            return nil unless values.size == 1 && keywords.empty? && (values[0].is_a?(Symbol) || values[0].is_a?(String))

            cstr = values[0].to_s
            return nil if seen_cols[cstr]

            seen_cols[cstr] = true
            col_sqls << "#{quote_column_name(cstr)} #{PRIMARY_KEY_SQL}"
          else
            return nil if values.empty?
            return nil unless keywords.each_key.all? { |k| FAST_COLUMN_OPTS.key?(k) }

            values.each do |cname|
              return nil unless append_fast_column(col_sqls, seen_cols, inline_indexes, cname, method_name, keywords)
            end
          end
        end

        return nil if col_sqls.empty?

        stmts = ["CREATE TABLE #{quote_table_name(table)} (#{col_sqls.join(', ')})"]
        inline_indexes.each do |icols, iopts|
          isql = fast_index_sql(table, icols, iopts)
          return nil unless isql

          stmts << isql
        end
        stmts
      end

      def append_fast_column(col_sqls, seen_cols, inline_indexes, cname, ctype, keywords)
        return false unless cname.is_a?(Symbol) || cname.is_a?(String)

        cstr = cname.to_s
        return false if seen_cols[cstr]

        seen_cols[cstr] = true
        col_opts =
          if keywords.key?(:index)
            idx_val = keywords[:index]
            return false unless idx_val == true || idx_val == false || idx_val.nil?

            inline_indexes << [cstr, {}] if idx_val
            keywords.except(:index)
          else
            keywords
          end

        csql = format_column_def(cstr, ctype, col_opts, for_create_table: true)
        return false unless csql

        col_sqls << csql
        true
      end
    end
  end
end
