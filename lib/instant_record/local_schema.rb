module InstantRecord
  # Bringing a local database up to the app's current schema, at boot.
  #
  # `DatabaseTasks.prepare_all` is the whole story on a server: a process starts
  # in Rails.root, so the relative "db/migrate" that ActiveRecord::Migrator
  # defaults to resolves. In the browser the VM's working directory is "/" while
  # the app is mounted at "/rails", so that path finds nothing: the migrator sees
  # zero migrations, reports nothing pending, and `prepare_all` is a silent
  # no-op. A returning visitor therefore keeps whatever schema their local
  # database was created with, and the first page touching a table added since
  # fails with "relation does not exist" — which is how two demos broke for
  # anyone who had booted the app before they existed.
  #
  # Pointing the migrator at absolute paths is not enough, and alone it is worse
  # than the no-op. These databases were built by `load_schema`, and its
  # `assume_migrated_upto_version` could only record the versions it could find —
  # which, with the paths broken, was the schema's own version and nothing else.
  # Make every migration discoverable and they all look pending, so boot replays
  # `create_table :issues` against a database that already has it, the install
  # raises, and the worker never activates.
  #
  # So the versions are reconciled first, by the rule
  # `assume_migrated_upto_version` would have used: db/schema.rb describes every
  # migration up to its own version, so a migration older than the highest
  # version this database has recorded is already in it, and gets stamped rather
  # than run. Anything newer is genuinely pending, and is migrated for real.
  #
  # That inherits one property from `assume_migrated_upto_version`: a migration
  # back-dated below a version this database already has is taken as applied,
  # not run. On a server `db:migrate` would run it. Here there is no history to
  # consult — only a schema that was loaded whole — so the version order is the
  # only evidence there is.
  module LocalSchema
    class << self
      # The browser runtime's schema step, in place of a bare `prepare_all`.
      def prepare!
        ActiveRecord::Tasks::DatabaseTasks.prepare_all

        # On a server the working directory already makes migrations findable,
        # and the stamping below would be wrong there: a back-dated migration on
        # a real migration history is genuinely pending, not implied by a schema
        # load that never happened.
        return unless InstantRecord.browser?

        catch_up!(migration_paths)
      end

      # Reconcile, then migrate. Takes the paths explicitly because the whole
      # bug is a path that only resolves from the right working directory.
      def catch_up!(paths)
        context = ActiveRecord::MigrationContext.new(paths)
        stamp_migrations_the_loaded_schema_already_contains(context)
        context.migrate
      end

      private

      # Absolute, and the app's own configured paths, so the engine's migrations
      # travel with the app's (see the "instant_record.migrations" initializer).
      def migration_paths
        Rails.application.config.paths["db/migrate"].existent
      end

      def stamp_migrations_the_loaded_schema_already_contains(context)
        recorded = context.get_all_versions
        baseline = recorded.max
        return unless baseline

        (context.migrations.map(&:version) - recorded)
          .select { |version| version < baseline }
          .each { |version| context.schema_migration.create_version(version) }
      end
    end
  end
end
