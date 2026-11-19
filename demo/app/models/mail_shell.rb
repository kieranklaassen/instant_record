require "sqlite3"

# A head start for a first sync: one SQLite file an inbox's browsers can open
# as their local database, holding what Mailbox#first_sync would have sent and
# stamped with the revision it was read at. It never has to be current. A
# browser that starts from it asks the change feed for everything after the
# stamp, and applying a change twice is an upsert, so an old file is slower to
# catch up and never wrong.
#
# The file's name carries the stamp: <inbox>.<cursor>.<fingerprint>.sqlite3.
# A demo's worth of design, kept out of the gem until its shape settles.
class MailShell
  FORMAT = 1

  # The models the compiled demo syncs (compiled/pipeline/make_wasm_entry.py).
  # The browser rebuilds its schema and forgets its cursor when its own list
  # differs from the one saved in its database, so the list is part of the
  # fingerprint and a build with another list never asks for this file.
  MODELS = %w[Channel ChatUser Issue MailEntry Message Note].freeze

  # Rebuild once a file is this far behind. Catch-up stays short.
  REBUILD_AFTER_CHANGES = 200
  REBUILD_AFTER = 1.hour

  # Past this a browser takes the normal bootstrap. The mail feed keeps every
  # entry, so these stand where a pruned feed's retention would: REBUILD_AFTER
  # has to stay well under SERVE_WITHIN, or a file could outlive the changes
  # that bring it up to date.
  SERVE_WITHIN_CHANGES = 1_000
  SERVE_WITHIN = 24.hours

  URL_LIFETIME = 5.minutes

  SQLITE_TYPES = { string: "varchar", text: "text", integer: "integer", bigint: "integer", float: "float",
    decimal: "decimal", datetime: "datetime(6)", date: "date", boolean: "boolean", json: "json", jsonb: "json" }.freeze
  SERVER_TABLES = %w[schema_migrations ar_internal_metadata].freeze

  attr_reader :path, :inbox, :cursor

  class << self
    attr_writer :root

    def root = @root ||= Rails.root.join("storage/mail_shells")

    # What a browser build and this server must agree on before a file made
    # here may stand in for a database made there. compiled/pipeline/build.py
    # computes the same digest into the worker.
    def fingerprint
      @fingerprint ||= Digest::SHA256.hexdigest([FORMAT, MODELS.join(","), Rails.root.join("db/schema.rb").read].join("\n"))
    end

    def latest(inbox)
      Dir.glob(root.join("#{inbox}.*.#{fingerprint.first(16)}.sqlite3").to_s).map { |path| new(path) }.max_by(&:cursor)
    end

    # One build at a time for an inbox, and none when a request that raced this
    # one already brought the file up to date.
    def build(mailbox)
      FileUtils.mkdir_p(root)
      File.open(root.join("#{mailbox.id}.lock"), "w") do |lock|
        return latest(mailbox.id) unless lock.flock(File::LOCK_EX | File::LOCK_NB)

        current = latest(mailbox.id)
        return current if current && !current.stale?(mailbox.reload.revision)

        write(mailbox.id, **snapshot(mailbox))
      end
    end

    def verifier
      @verifier ||= ActiveSupport::MessageVerifier.new(Rails.application.key_generator.generate_key("mail_shell"), url_safe: true, serializer: JSON)
    end

    def find_signed(token, member:, inbox:)
      grant = verifier.verified(token, purpose: :mail_shell)
      return unless grant && grant["member"] == member && grant["inbox"] == inbox && grant["file"].start_with?("#{inbox}.")

      path = root.join(File.basename(grant["file"]))
      new(path.to_s) if path.file?
    end

    private

    # The stamp and the rows have to be one read. Repeatable read makes them
    # one snapshot. Inside someone else's transaction that level cannot be
    # asked for, and Mailbox#first_sync reading the revision first keeps the
    # stamp from ever being ahead of the rows.
    def snapshot(mailbox)
      isolated = Mailbox.connection.open_transactions.zero? && Mailbox.connection.supports_transaction_isolation?
      Mailbox.transaction(**(isolated ? { isolation: :repeatable_read } : {})) { mailbox.first_sync }
    end

    def write(inbox, cursor:, records:)
      final = root.join("#{inbox}.#{cursor}.#{fingerprint.first(16)}.sqlite3")
      draft = root.join("#{final.basename}.#{SecureRandom.hex(4)}.tmp")
      stamp = Time.current.utc.iso8601(InstantRecord::TIME_PRECISION)
      database = SQLite3::Database.new(draft.to_s)
      # Most of the schema's tables are empty in an inbox's shell, and an empty
      # table or index still takes a page. Small pages keep the download small.
      database.execute("PRAGMA page_size = 1024")
      database.transaction do
        schema_statements.each { |sql| database.execute(sql) }
        records.each { |record| insert(database, record) }
        # The cursor goes in last, as the client writes it after a bootstrap:
        # a database without one is a database that still has to sync.
        { "compiled_models" => MODELS.join(","), "shell_fingerprint" => fingerprint, "cursor" => cursor.to_s }.each do |key, value|
          database.execute("INSERT INTO instant_record_sync_metadata (key, value, created_at, updated_at) VALUES (?, ?, ?, ?)", [key, value, stamp, stamp])
        end
      end
      database.execute("VACUUM")
      database.close
      File.rename(draft, final)
      # A file someone was just handed an address for stays until that address runs out.
      Dir.glob(root.join("#{inbox}.*.sqlite3").to_s).each do |old|
        File.delete(old) if old != final.to_s && File.mtime(old) < URL_LIFETIME.ago
      end
      new(final.to_s)
    ensure
      database&.close unless database&.closed?
      FileUtils.rm_f(draft) if draft
    end

    # A row as the client's upsert would leave it: the wire's own values, the
    # version it arrived at, and nothing waiting to be sent.
    def insert(database, record)
      model = record[:type].constantize
      attributes = record[:attributes].slice(*model.column_names)
      attributes["server_version"] = record[:version] || attributes["server_version"] || 0
      attributes["sync_state"] = "synced"
      columns = attributes.keys.map { |name| %("#{name}") }.join(", ")
      values = attributes.values.map { |value| value == true ? 1 : value == false ? 0 : value }
      database.execute(%(INSERT INTO "#{model.table_name}" (#{columns}) VALUES (#{(["?"] * values.size).join(", ")})), values)
    end

    # Every table of db/schema.rb, which is the schema the browser carries.
    def schema_statements
      connection = ActiveRecord::Base.connection
      (connection.tables - SERVER_TABLES).sort.flat_map do |table|
        keys = Array(connection.primary_key(table))
        columns = connection.columns(table).map do |column|
          sql = %("#{column.name}" #{SQLITE_TYPES.fetch(column.type, "text")})
          sql << " NOT NULL" unless column.null
          sql << " DEFAULT #{connection.quote(column.default)}" if column.default && !column.default_function
          # An integer key has to be SQLite's rowid for inserts without an id to number themselves.
          sql << " PRIMARY KEY AUTOINCREMENT" if keys == [column.name] && %i[integer bigint].include?(column.type)
          sql
        end
        columns << "PRIMARY KEY (#{keys.map { |key| %("#{key}") }.join(", ")})" if keys.any? && columns.none? { |sql| sql.include?("AUTOINCREMENT") }
        indexes = connection.indexes(table).select { |index| index.columns.is_a?(Array) && index.where.nil? }.map do |index|
          %(CREATE #{"UNIQUE " if index.unique}INDEX "#{index.name}" ON "#{table}" (#{index.columns.map { |name| %("#{name}") }.join(", ")}))
        end
        [%(CREATE TABLE "#{table}" (#{columns.join(", ")})), *indexes]
      end
    end
  end

  def initialize(path)
    @path = path
    @inbox, cursor, = File.basename(path).split(".")
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

  def signed_token(member)
    self.class.verifier.generate({ "member" => member, "inbox" => inbox, "file" => File.basename(path) }, expires_in: URL_LIFETIME, purpose: :mail_shell)
  end
end
