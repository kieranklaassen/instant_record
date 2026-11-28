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
      SQLITE_FILE_SUFFIXES = ["", "-wal", "-shm", "-journal"].freeze

      attr_reader :branch_path

      class << self
        def fork!(name:, directory: nil)
          config = ActiveRecord::Base.connection_db_config.configuration_hash.dup
          adapter = config[:adapter].to_s
          unless adapter.include?("sqlite")
            raise Branch::Error, "Staging branches require a local SQLite database (got #{adapter.inspect})"
          end

          db_spec = config[:database].to_s
          memory = db_spec == ":memory:" || db_spec.empty?
          token = SecureRandom.hex(8)
          safe_name = sanitize_name(name)

          work_dir = directory || (memory ? Dir.mktmpdir("instant_record_branch_") : File.dirname(File.expand_path(db_spec)))
          owns_dir = memory && directory.nil?
          branch_path = File.join(work_dir, ".ir-branch-#{safe_name}-#{token}.sqlite3")
          main_backup_path = memory ? File.join(work_dir, ".ir-main-#{token}.sqlite3") : nil

          store = new(
            main_config: config,
            branch_path: branch_path,
            main_backup_path: main_backup_path,
            owns_dir: owns_dir ? work_dir : nil
          )

          activating = false
          completed = false
          begin
            FileUtils.mkdir_p(work_dir)
            src_raw = ActiveRecord::Base.connection.raw_connection
            if memory
              backup_database(src_raw, main_backup_path)
              FileUtils.cp(main_backup_path, branch_path)
            else
              backup_database(src_raw, branch_path)
            end

            activating = true
            store.activate_branch!
            completed = true
            store
          ensure
            unless completed
              if activating
                begin
                  store.restore_main!
                rescue StandardError
                  nil
                end
              end
              begin
                store.cleanup!
              rescue StandardError
                nil
              end
            end
          end
        end

        def backup_database(source_db, destination_path)
          require "sqlite3"
          dest = SQLite3::Database.new(destination_path)
          copy_database(source_db, dest)
        ensure
          dest&.close
        end

        def restore_into_memory(source_path, memory_db)
          require "sqlite3"
          src = SQLite3::Database.new(source_path)
          copy_database(src, memory_db)
        ensure
          src&.close
        end

        private

        def copy_database(source_db, destination_db)
          backup = SQLite3::Backup.new(destination_db, "main", source_db, "main")
          status = backup.step(-1)
          unless status == SQLite3::Constants::ErrorCode::DONE
            raise Branch::Error, "SQLite backup failed with status #{status}"
          end
        ensure
          backup&.finish
        end

        def sanitize_name(name)
          cleaned = name.to_s
            .gsub(/[^a-zA-Z0-9_-]+/, "-")
            .gsub(/\A-+|-+\z/, "")
            .slice(0, 32)
            .sub(/-+\z/, "")
          cleaned.empty? ? "staging" : cleaned
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
        reconnect_to(@main_config)
        if @main_backup_path
          self.class.restore_into_memory(@main_backup_path, ActiveRecord::Base.connection.raw_connection)
        end
      end

      def cleanup!
        remove_sqlite_files(@branch_path)
      ensure
        begin
          remove_sqlite_files(@main_backup_path)
        ensure
          FileUtils.rm_rf(@owns_dir) if @owns_dir && !@owns_dir.empty?
        end
      end

      private

      def reconnect_to(config)
        ActiveRecord::Base.connection_handler.clear_all_connections!
        ActiveRecord::Base.establish_connection(config)
        ActiveRecord::Base.connection
      end

      def remove_sqlite_files(base_path)
        return unless base_path

        SQLITE_FILE_SUFFIXES.each do |suffix|
          FileUtils.rm_f("#{base_path}#{suffix}")
        end
      end
    end

    self.store_class = SqliteStore
  end
end
