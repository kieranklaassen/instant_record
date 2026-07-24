require "test_helper"
require "tmpdir"
require "fileutils"

# What a returning visitor's database looks like, and what boot has to do with
# it: created by `load_schema`, so `schema_migrations` holds the schema's own
# version and little else, and since then the app grew a table. The catch-up has
# to tell those two kinds of "pending" apart — a migration the loaded schema
# already contains must be stamped, one added since must actually run — and it
# has to do it from a working directory that is not Rails.root, because the
# browser VM's is "/".
class LocalSchemaTest < Minitest::Test
  # The version the local database was built at: everything below it is already
  # in the schema that was loaded, everything above it is genuinely pending.
  BASELINE = 20260101000000

  # The suite shares one in-memory database, and the gem's own migrations are
  # recorded in it — so this test keeps its migration history in a table of its
  # own rather than reasoning about versions it does not control.
  VERSIONS_TABLE = "local_schema_test_migrations".freeze

  def setup
    @dir = Dir.mktmpdir("instant_record_local_schema")
    write_migration(BASELINE - 1, "CreateAlreadyThere", "already_there")
    write_migration(BASELINE + 1, "CreateAddedSince", "added_since")

    @previous_versions_table = ActiveRecord::Base.schema_migrations_table_name
    ActiveRecord::Base.schema_migrations_table_name = VERSIONS_TABLE

    schema_migration.create_table
    schema_migration.create_version(BASELINE)
    connection.create_table(:already_there, force: true) { |t| t.string :name }
  end

  def teardown
    schema_migration.drop_table
    ActiveRecord::Base.schema_migrations_table_name = @previous_versions_table
    connection.drop_table(:already_there, if_exists: true)
    connection.drop_table(:added_since, if_exists: true)
    FileUtils.remove_entry(@dir)
  end

  def test_migrations_the_loaded_schema_already_contains_are_stamped_not_replayed
    catch_up

    assert_includes recorded_versions, BASELINE - 1,
      "a migration older than the schema this database was built from must be recorded as applied"
  end

  def test_migrations_added_since_are_applied
    refute connection.table_exists?(:added_since)

    catch_up

    assert connection.table_exists?(:added_since),
      "a table added after this database was created must exist after boot"
    assert_includes recorded_versions, BASELINE + 1
  end

  def test_a_second_catch_up_changes_nothing
    catch_up
    before = recorded_versions

    catch_up

    assert_equal before, recorded_versions
  end

  private

  # From "/", which is where the browser VM's working directory actually is —
  # the relative path Rails defaults to finds nothing from there.
  def catch_up
    Dir.chdir("/") { InstantRecord::LocalSchema.catch_up!(@dir) }
  end

  def connection = ActiveRecord::Base.connection

  # Deliberately not the pool's memoized one: this builds against whichever
  # table name is set right now.
  def schema_migration = ActiveRecord::SchemaMigration.new(ActiveRecord::Base.connection_pool)

  def recorded_versions = schema_migration.integer_versions.sort

  def write_migration(version, class_name, table)
    File.write(File.join(@dir, "#{version}_#{class_name.underscore}.rb"), <<~RUBY)
      class #{class_name} < ActiveRecord::Migration[8.1]
        def change
          create_table :#{table} do |t|
            t.string :name
          end
        end
      end
    RUBY
  end
end
