# The v2 release the /migrate demo ships on demand.
#
# The teaching migration lives outside db/migrate so it runs only on request.
class Release
  MIGRATIONS_PATH = Rails.root.join("db/v2_migrate").to_s

  # The column v2 adds. One constant so the page can describe the change and
  # the tests can assert it without either restating the migration.
  COLUMN = "word_count".freeze

  class << self
    def pending?
      context.needs_migration?
    end

    def version
      context.migrations.last.version
    end

    # Runs the migration against whatever the local database already holds —
    # rows, and an outbox that may still be full.
    #
    # reset_column_information is not optional here. A migration run from a
    # rake task gets a fresh process afterwards; this one runs inside a
    # long-lived VM that keeps serving requests, so the model has to be told
    # its columns moved or every later render still describes v1.
    def ship
      context.migrate
      Note.reset_column_information
    end

    # Put the local database back on v1 so the demo can be run again. Without
    # this the page is one-shot: the first visitor ships, and everyone after
    # them arrives to a migration that is already applied with nothing left to
    # watch. The migration is an `add_column` inside `change`, so this is a real
    # reversal rather than a pretend one — the column goes away, and the rows and
    # their timestamps stay exactly where they were, which is also the claim the
    # demo makes about shipping forward.
    def roll_back
      context.migrate(0)
      Note.reset_column_information
    end

    # Read from the connection, not from Note.column_names: the whole point of
    # the page is what the local database actually holds at this moment, not
    # what the model believes.
    def local_columns
      Note.with_connection { |connection| connection.columns(Note.table_name).map(&:name) }
    end

    private

    def context
      ActiveRecord::MigrationContext.new(MIGRATIONS_PATH)
    end
  end
end
