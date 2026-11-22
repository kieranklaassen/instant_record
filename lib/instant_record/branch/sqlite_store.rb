require "fileutils"
require "securerandom"
require "tmpdir"

module InstantRecord
  class Branch
    # CRuby SQLite copy-on-write snapshot & connection switcher.
    #
    # Uses SQLite's online backup API (SQLite3::Backup) so both file-backed
    # databases and `:memory:` databases snapshot transactionally without
    # disturbing WAL state or concurrent readers.
    #
    # For file-backed databases, `main` stays at its original path on disk so
    # external connections or `branch.on_main` can continue applying remote
    # deltas while the staging branch is open; `restore_main!` reconnects
    # directly to that live `main` file without overwriting it.
    class SqliteStore
      attr_reader :branch_path

      def self.fork!(name:, directory: nil)
        config = ActiveRecord::Base.connection_db_config.configuration_hash.dup
        adapter = config[:adapter].to_s
        unless adapter.include?("sqlite")
          raise Branch::Error, "Staging branches require a local SQLite database (got #{adapter.inspect})"
        end

        db_spec = config[:database].to_s
        memory = db_spec == ":memory:" || db_spec.empty?
        token = SecureRandom.hex(8)
        safe_name = name.to_s.gsub(/[^a-zA-Z0-9_-]+/, "-").slice(0, 32)
        safe_name = "staging" if safe_name.empty?

        work_dir = directory || (memory ? Dir.mktmpdir("instant_record_branch_") : File.dirname(File.expand_path(db_spec)))
        FileUtils.mkdir_p(work_dir)
        owns_dir = memory && directory.nil?

        branch_path = File.join(work_dir, ".ir-branch-#{safe_name}-#{token}.sqlite3")
        main_backup_path = memory ? File.join(work_dir, ".ir-main-#{token}.sqlite3") : nil

        src_raw = ActiveRecord::Base.connection.raw_connection
        if memory
          backup_database(src_raw, main_backup_path)
          FileUtils.cp(main_backup_path, branch_path)
        else
          backup_database(src_raw, branch_path)
        end

        store = new(
          main_config: config,
          branch_path: branch_path,
          main_backup_path: main_backup_path,
          owns_dir: owns_dir ? work_dir : nil
        )
        store.activate_branch!
        store
      end

      def self.backup_database(source_db, destination_path)
        require "sqlite3"
        dest = SQLite3::Database.new(destination_path)
        begin
          backup = SQLite3::Backup.new(dest, "main", source_db, "main")
          begin
            backup.step(-1)
          ensure
            backup.finish
          end
        ensure
          dest.close
        end
      end

      def self.restore_into_memory(source_path, memory_db)
        require "sqlite3"
        src = SQLite3::Database.new(source_path)
        begin
          backup = SQLite3::Backup.new(memory_db, "main", src, "main")
          begin
            backup.step(-1)
          ensure
            backup.finish
          end
        ensure
          src.close
        end
      end

      def initialize(main_config:, branch_path:, main_backup_path:, owns_dir:)
        @main_config = main_config
        @branch_path = branch_path
        @main_backup_path = main_backup_path
        @owns_dir = owns_dir
      end

      def activate_branch!
        reconnect_to(@main_config.merge(database: @branch_path))
      end

      def with_main
        target_config = @main_backup_path ? @main_config.merge(database: @main_backup_path) : @main_config
        reconnect_to(target_config)
        yield
      ensure
        activate_branch!
      end

      def restore_main!
        if @main_backup_path
          reconnect_to(@main_config)
          self.class.restore_into_memory(@main_backup_path, ActiveRecord::Base.connection.raw_connection)
        else
          reconnect_to(@main_config)
        end
      end

      def cleanup!
        remove_sqlite_files(@branch_path)
        remove_sqlite_files(@main_backup_path) if @main_backup_path
        FileUtils.rm_rf(@owns_dir) if @owns_dir && File.directory?(@owns_dir)
      end

      private

      def reconnect_to(config)
        ActiveRecord::Base.connection_handler.clear_all_connections!
        ActiveRecord::Base.establish_connection(config)
        ActiveRecord::Base.connection
      end

      def remove_sqlite_files(base_path)
        return unless base_path

        ["", "-wal", "-shm", "-journal"].each do |suffix|
          file = "#{base_path}#{suffix}"
          FileUtils.rm_f(file) if File.exist?(file)
        end
      end
    end

    self.store_class = SqliteStore
  end
end
