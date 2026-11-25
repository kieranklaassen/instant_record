require "digest"
require "fileutils"
require "json"
require "pathname"
require "securerandom"
require "sqlite3"
require "time"
require "active_support/core_ext/numeric/time"
require "active_support/message_verifier"
require "instant_record/compiler/browser_migrations"
require "instant_record/sync_scope"

module InstantRecord
  # A head start for a first sync: one prebuilt SQLite file a browser or native
  # iOS app can open as its local database, holding what bootstrap would send
  # and stamped with the cursor it was read at. It never has to be current: a
  # client that starts from it polls the change feed from the stamp, and
  # applying a change twice is an idempotent upsert, so an older shell is slower
  # to catch up and never wrong.
  #
  # Partitioned per SyncScope (both identity key and scope token) so private
  # rows are never shared across callers or written into public caches.
  #
  # The file's name carries the stamp: <partition>.<cursor>.<fingerprint>.sqlite3.
  class Shell
    FORMAT = 1

    # Rebuild once a file is this far behind. Catch-up stays short.
    REBUILD_AFTER_CHANGES = 200
    REBUILD_AFTER = 1.hour

    # Past this a client takes the normal bootstrap instead of a stale shell.
    SERVE_WITHIN_CHANGES = 1_000
    SERVE_WITHIN = 24.hours

    URL_LIFETIME = 5.minutes
    SIGNING_PURPOSE = :instant_record_shell
    SQLITE_HEADER = "SQLite format 3\x00".b.freeze
    PARTITION_PATTERN = /\A[A-Za-z0-9_-]+\z/

    # How the compiled runtime stores a datetime: UTC, a space, six decimals and
    # no zone ("2026-11-19 06:10:30.814075"). Queries order by this text, so a
    # row written any other way sorts apart from rows that sync in later.
    DB_TIME = "%Y-%m-%d %H:%M:%S.%6N"

    SQLITE_TYPES = {
      string: "varchar",
      text: "text",
      integer: "integer",
      bigint: "integer",
      float: "float",
      decimal: "decimal",
      datetime: "datetime(6)",
      date: "date",
      boolean: "boolean",
      json: "json",
      jsonb: "json"
    }.freeze

    SERVER_TABLES = %w[schema_migrations ar_internal_metadata].freeze

    attr_reader :path, :partition, :cursor

    class << self
      attr_writer :root, :models, :verifier, :identity_serializer, :identity_deserializer

      def root
        @root ||= if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
          Rails.root.join("storage/instant_record/shells")
        else
          Pathname(Dir.tmpdir).join("instant_record_shells")
        end
      end

      def models
        resolved_models
      end

      # Named custom shell sources (for feeds that manage their own cursor and
      # bootstrap snapshot, like the demo's shared Inbox).
      def sources
        @sources ||= {}
      end

      def register(name, &block)
        sources[name.to_s] = block
      end

      # What a compiled build (browser Wasm or Native iOS) and this server must
      # agree on before a file built here may stand in for a database created
      # there. WasmBuild and NativeBuild compute the same digest.
      def fingerprint(models: nil, schema: nil, schema_path: nil)
        model_list = resolved_models(models).join(",")
        schema_source = if !schema.nil?
          schema.to_s
        elsif (path = schema_path || default_schema_path) && File.file?(path)
          File.read(path)
        else
          connection_schema_statements.join("\n")
        end
        Digest::SHA256.hexdigest([FORMAT, model_list, schema_source].join("\n"))
      end

      # Opaque, filesystem-safe partition name for one SyncScope caller. Hashes
      # BOTH SyncScope.key (syncable_to / auth identity) and SyncScope.token
      # (sync_scope column) so callers differing on either dimension never share
      # a shell file.
      def partition_key(identity)
        Digest::SHA256.hexdigest([SyncScope.key(identity), SyncScope.token(identity).to_s].join("\0"))[0, 24]
      end

      def valid_sqlite?(bytes)
        bytes.respond_to?(:bytesize) && bytes.bytesize >= SQLITE_HEADER.bytesize &&
          bytes.byteslice(0, SQLITE_HEADER.bytesize) == SQLITE_HEADER
      end

      def serializable_identity?(identity)
        return true if @identity_serializer
        return true if identity.nil? || identity.is_a?(String) || identity.is_a?(Integer)
        return true if defined?(GlobalID::Identification) && identity.is_a?(GlobalID::Identification)

        false
      end

      def dump_identity(identity)
        return { "custom" => true, "value" => @identity_serializer.call(identity) } if @identity_serializer

        identity
      end

      def load_identity(payload)
        if @identity_deserializer && payload.is_a?(Hash) && payload["custom"]
          return @identity_deserializer.call(payload["value"])
        end

        payload
      end

      def latest(partition, fingerprint: nil, root: nil)
        name = validate_partition!(partition)
        fp = (fingerprint || self.fingerprint).first(16)
        dir = Pathname(root || self.root)
        Dir.glob(dir.join("#{name}.*.#{fp}.sqlite3").to_s).map { |path| new(path) }.max_by(&:cursor)
      end

      # One build at a time per partition, and none when a racing request
      # already brought the file up to date.
      def build(identity: nil, partition: nil, revision: nil, models: nil, identity_key: :auto,
                root: nil, app_root: nil, migration_paths: nil, &snapshot_block)
        name = validate_partition!(partition || partition_key(identity))
        dir = Pathname(root || self.root)
        schema_root = app_root || default_app_root
        schema_file = schema_root ? File.join(schema_root.to_s, "db/schema.rb") : nil
        model_list = resolved_models(models)
        fp = fingerprint(models: model_list, schema_path: schema_file)

        FileUtils.mkdir_p(dir)
        File.open(dir.join("#{name}.lock"), "w") do |lock|
          return latest(name, fingerprint: fp, root: dir) unless lock.flock(File::LOCK_EX | File::LOCK_NB)

          current_rev = revision.respond_to?(:call) ? revision.call : (revision || Change.maximum(:id) || 0)
          current = latest(name, fingerprint: fp, root: dir)
          return current if current && !current.stale?(current_rev)

          snap = take_snapshot(identity: identity, models: models, &snapshot_block)
          resolved_identity = if snap.key?(:identity)
            snap[:identity]
          elsif identity_key == :auto
            SyncScope.key(identity)
          else
            identity_key
          end

          ddl = resolve_schema_ddl(app_root: schema_root, migration_paths: migration_paths)
          write(
            name,
            cursor: snap.fetch(:cursor),
            records: snap.fetch(:records),
            fingerprint: fp,
            models: model_list,
            identity_key: resolved_identity,
            ddl: ddl,
            root: dir
          )
        end
      end

      def build_source(name, arg = nil, **options)
        builder = sources[name.to_s]
        raise ArgumentError, "Unknown shell source: #{name.inspect}" unless builder

        spec = builder.call(arg)
        return nil unless spec

        snapshot_proc = spec.fetch(:snapshot)
        build(
          partition: spec.fetch(:partition),
          revision: spec[:revision],
          models: spec[:models] || options[:models],
          identity_key: spec.key?(:identity_key) ? spec[:identity_key] : nil,
          root: options[:root],
          app_root: options[:app_root],
          migration_paths: options[:migration_paths],
          &snapshot_proc
        )
      end

      # Model-agnostic bootstrap snapshot: change-log cursor read BEFORE rows
      # inside one transaction, filtered by SyncWindow and SyncScope.visible.
      def snapshot(identity: nil, models: nil)
        in_snapshot_transaction do
          cursor = Change.maximum(:id) || 0
          records = snapshot_models(models).flat_map do |model|
            visible = SyncScope.visible(model, identity)
            window = model.instant_record_sync_window
            rows = window ? window.in_window(visible) : visible
            InstantRecord.record_payloads(rows)
          end
          { cursor: cursor, records: records }
        end
      end

      def verifier
        @verifier ||= begin
          secret = if defined?(Rails) && Rails.application
            Rails.application.key_generator.generate_key("instant_record_shell")
          else
            @fallback_secret ||= SecureRandom.random_bytes(32)
          end
          ActiveSupport::MessageVerifier.new(secret, url_safe: true, serializer: JSON)
        end
      end

      def find_signed(token, partition:, holder: nil, root: nil)
        return if token.to_s.empty?

        name = validate_partition!(partition)
        expected_holder = (holder.nil? ? name : holder).to_s
        grant = verifier.verified(token, purpose: SIGNING_PURPOSE)
        return unless grant.is_a?(Hash) &&
          grant["partition"] == name &&
          grant["holder"] == expected_holder &&
          grant["file"].is_a?(String) &&
          File.basename(grant["file"]) == grant["file"] &&
          grant["file"].start_with?("#{name}.")

        path = Pathname(root || self.root).join(File.basename(grant["file"]))
        new(path.to_s) if path.file?
      rescue ArgumentError
        nil
      end

      # Resolve SQLite DDL statements and schema version, preferring
      # BrowserMigrations (the same SQLite DDL the compiled client uses) and
      # falling back to ActiveRecord connection introspection when no
      # db/schema.rb or portable migrations are present.
      def resolve_schema_ddl(app_root: default_app_root, migration_paths: nil)
        if app_root && File.file?(File.join(app_root.to_s, "db/schema.rb"))
          paths = migration_paths || default_migration_paths(app_root)
          if paths.any? { |dir| File.directory?(dir) && Dir.glob("[0-9]*_*.rb", base: dir).any? }
            begin
              return Compiler::BrowserMigrations.schema_ddl(root: app_root.to_s, migration_paths: paths)
            rescue Compiler::BuildError
              # Fall back to live connection introspection if an app has a
              # pre-baseline non-portable migration without a .sql companion.
            end
          end
          version = extract_schema_version(File.join(app_root.to_s, "db/schema.rb"))
          return { version: version, statements: connection_schema_statements }
        end

        { version: nil, statements: connection_schema_statements }
      end

      private

      def validate_partition!(partition)
        name = partition.to_s
        raise ArgumentError, "Invalid shell partition: #{partition.inspect}" unless PARTITION_PATTERN.match?(name)

        name
      end

      def default_app_root
        Rails.root if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
      end

      def default_schema_path
        root_dir = default_app_root
        root_dir&.join("db/schema.rb")
      end

      def default_migration_paths(app_root)
        if defined?(Rails) && Rails.application && Rails.application.root.to_s == app_root.to_s
          Rails.application.config.paths["db/migrate"].existent
        else
          [File.join(app_root.to_s, "db/migrate")]
        end
      end

      def eager_load_if_rails!
        if defined?(Rails) && Rails.application && !Rails.application.config.eager_load
          Rails.application.eager_load!
        end
      end

      def resolved_models(explicit = nil)
        list = if explicit
          Array(explicit).map { |m| m.is_a?(Class) ? m.name : m.to_s }
        elsif @models
          Array(@models).map(&:to_s)
        else
          eager_load_if_rails!
          InstantRecord.syncable_models.map(&:name)
        end
        list.compact.sort
      end

      def snapshot_models(explicit = nil)
        if explicit
          Array(explicit).filter_map { |m| m.is_a?(Class) ? m : InstantRecord.synced_model(m.to_s) }
        else
          eager_load_if_rails!
          InstantRecord.syncable_models
        end
      end

      def take_snapshot(identity:, models:, &snapshot_block)
        if snapshot_block
          in_snapshot_transaction(&snapshot_block)
        else
          snapshot(identity: identity, models: models)
        end
      end

      def in_snapshot_transaction(&block)
        conn = ActiveRecord::Base.connection
        isolated = conn.open_transactions.zero? && conn.supports_transaction_isolation? && !conn.adapter_name.match?(/sqlite/i)
        ActiveRecord::Base.transaction(**(isolated ? { isolation: :repeatable_read } : {})) { block.call }
      end

      def write(partition, cursor:, records:, fingerprint:, models:, identity_key:, ddl:, root:)
        final = root.join("#{partition}.#{cursor}.#{fingerprint.first(16)}.sqlite3")
        draft = root.join("#{final.basename}.#{SecureRandom.hex(4)}.tmp")
        stamp = Time.current.utc.strftime(DB_TIME)
        database = SQLite3::Database.new(draft.to_s)
        # Most tables in a shell may be empty, and an empty table or index still
        # takes a page. Small pages keep the download small.
        database.execute("PRAGMA page_size = 1024")
        database.transaction do
          ddl.fetch(:statements).each { |sql| database.execute(sql) }
          records.each { |record| insert(database, record) }

          metadata = {
            "compiled_models" => models.join(","),
            "shell_fingerprint" => fingerprint
          }
          metadata["schema_version"] = format("%020d", ddl[:version].to_i) if ddl[:version]
          metadata["identity"] = identity_key.to_s if identity_key && !identity_key.to_s.empty?
          # Cursor goes in last, matching the client's bootstrap invariant:
          # a database without one is a database that still has to sync.
          metadata["cursor"] = cursor.to_s

          metadata.each do |key, value|
            database.execute(
              "INSERT INTO instant_record_sync_metadata (key, value, created_at, updated_at) VALUES (?, ?, ?, ?)",
              [key, value, stamp, stamp]
            )
          end
        end
        database.execute("VACUUM")
        database.close
        File.rename(draft, final)

        # Keep files that may still have live signed URLs until URL_LIFETIME passes.
        Dir.glob(root.join("#{partition}.*.sqlite3").to_s).each do |old|
          File.delete(old) if old != final.to_s && File.mtime(old) < URL_LIFETIME.ago
        end
        new(final.to_s)
      ensure
        database&.close unless database&.closed?
        FileUtils.rm_f(draft) if draft
      end

      # A row as the client's upsert would leave it: wire values with datetimes
      # in the compiled runtime's format, server_version set, sync_state synced.
      def insert(database, record)
        type = record[:type] || record["type"]
        model = InstantRecord.synced_model(type) || type.to_s.constantize
        raw = record[:attributes] || record["attributes"] || {}
        attributes = raw.transform_keys(&:to_s).slice(*model.column_names)
        if model.column_names.include?("server_version")
          attributes["server_version"] = record[:version] || record["version"] || attributes["server_version"] || 0
        end
        attributes["sync_state"] = "synced" if model.column_names.include?("sync_state")

        model.columns.each do |column|
          val = attributes[column.name]
          next if val.nil?

          if column.type == :datetime
            attributes[column.name] = format_datetime(val)
          elsif column.type == :date && val.is_a?(Date)
            attributes[column.name] = val.iso8601
          end
        end

        columns = attributes.keys.map { |name| %("#{name}") }.join(", ")
        values = attributes.values.map { |value| sqlite_value(value) }
        placeholders = (["?"] * values.size).join(", ")
        database.execute(%(INSERT INTO "#{model.table_name}" (#{columns}) VALUES (#{placeholders})), values)
      end

      def format_datetime(value)
        time = value.is_a?(String) ? Time.iso8601(value) : value.to_time
        time.utc.strftime(DB_TIME)
      rescue ArgumentError
        Time.parse(value.to_s).utc.strftime(DB_TIME)
      end

      def sqlite_value(value)
        case value
        when true then 1
        when false then 0
        when Hash, Array then JSON.generate(value)
        else value
        end
      end

      def extract_schema_version(schema_path)
        match = File.read(schema_path).match(/\.define\s*\(\s*version:\s*([\d_]+)/)
        match ? Integer(match[1], 10) : nil
      end

      def connection_schema_statements
        connection = ActiveRecord::Base.connection
        (connection.tables - SERVER_TABLES).sort.flat_map do |table|
          keys = Array(connection.primary_key(table))
          columns = connection.columns(table).map do |column|
            sql = %("#{column.name}" #{SQLITE_TYPES.fetch(column.type, "text")})
            sql << " NOT NULL" unless column.null
            sql << " DEFAULT #{connection.quote(column.default)}" if column.default && !column.default_function
            sql << " PRIMARY KEY AUTOINCREMENT" if keys == [column.name] && %i[integer bigint].include?(column.type)
            sql
          end
          if keys.any? && columns.none? { |sql| sql.include?("AUTOINCREMENT") }
            columns << "PRIMARY KEY (#{keys.map { |key| %("#{key}") }.join(", ")})"
          end
          indexes = connection.indexes(table).select { |index| index.columns.is_a?(Array) && index.where.nil? }.map do |index|
            %(CREATE #{"UNIQUE " if index.unique}INDEX "#{index.name}" ON "#{table}" (#{index.columns.map { |name| %("#{name}") }.join(", ")}))
          end
          [%(CREATE TABLE "#{table}" (#{columns.join(", ")})), *indexes]
        end
      end
    end

    def initialize(path)
      @path = path.to_s
      @partition, cursor, = File.basename(@path).split(".")
      @cursor = cursor.to_i
    end

    def built_at = File.mtime(path)
    def bytes = File.size(path)

    def stale?(revision)
      revision - cursor > REBUILD_AFTER_CHANGES || built_at < REBUILD_AFTER.ago
    end

    def servable?(revision)
      revision - cursor <= SERVE_WITHIN_CHANGES && built_at >= SERVE_WITHIN.ago
    end

    def signed_token(holder: nil)
      self.class.verifier.generate(
        {
          "partition" => partition,
          "holder" => (holder.nil? ? partition : holder).to_s,
          "file" => File.basename(path)
        },
        expires_in: URL_LIFETIME,
        purpose: SIGNING_PURPOSE
      )
    end
  end
end
