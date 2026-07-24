require "test_helper"

# The bug behind InstantRecord::LocalSchema, pinned end to end: the browser VM
# runs with a working directory of "/" while the app lives at "/rails", so the
# relative "db/migrate" that ActiveRecord::Migrator defaults to resolves to
# nothing. The migrator then finds zero migrations, reports nothing pending, and
# a bare `prepare_all` on boot is a silent no-op — so a returning client keeps
# whatever schema its local database was created with, and every table added
# since is missing. Pages touching one fail with "relation does not exist".
#
# Both halves are asserted against a real migration applied to the already-
# populated database: the absolute path applies it, the relative path silently
# does not.
class StaleDatabaseMigrationTest < ActiveSupport::TestCase
  # Migrating commits, so this cannot run inside the test transaction.
  self.use_transactional_tests = false

  PROBE_TABLE = "zz_stale_probe".freeze
  # Synthetic and deliberately old: Rails refuses a migration timestamped in the
  # future, and nothing in db/migrate uses 2020.
  PROBE_VERSION = "20200101000001".freeze

  def setup
    @dir = Dir.mktmpdir("instant_record_probe")
    File.write(File.join(@dir, "#{PROBE_VERSION}_create_#{PROBE_TABLE}.rb"), <<~RUBY)
      class CreateZzStaleProbe < ActiveRecord::Migration[8.1]
        def change
          create_table :#{PROBE_TABLE} do |t|
            t.string :name
          end
        end
      end
    RUBY
  end

  def teardown
    connection.drop_table(PROBE_TABLE, if_exists: true)
    connection.execute("DELETE FROM schema_migrations WHERE version = '#{PROBE_VERSION}'")
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
  end

  def connection
    ActiveRecord::Base.connection
  end

  test "an absolute migration path applies a pending migration to a database that already has data" do
    refute connection.table_exists?(PROBE_TABLE), "probe table leaked from an earlier run"
    assert Issue.table_exists?, "this has to run against the populated schema, not an empty database"

    Dir.chdir("/") do
      ActiveRecord::MigrationContext.new(@dir).migrate
    end

    assert connection.table_exists?(PROBE_TABLE),
      "an absolute path has to apply pending migrations regardless of the working directory"
  end

  # The failure mode itself. Nothing raises; the migrator simply has nothing to
  # do, which is why this went unnoticed until a demo added a table.
  test "a relative migration path silently applies nothing from a foreign working directory" do
    Dir.chdir("/") do
      context = ActiveRecord::MigrationContext.new("db/migrate")

      assert_empty context.migrations, "the relative path resolved, so this no longer reproduces the bug"
      refute context.needs_migration?, "with nothing found the migrator reports nothing pending"
      context.migrate
    end

    refute connection.table_exists?(PROBE_TABLE),
      "the relative path found no migrations, so nothing was applied"
  end
end
