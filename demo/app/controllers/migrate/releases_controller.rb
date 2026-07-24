module Migrate
  class ReleasesController < ApplicationController
    extend InstantRecord::RuntimeScoped

    browser_only do
      skip_forgery_protection   # no session secrets in the local runtime
    end

    # Ship v2: real DDL and a real backfill against the local database exactly
    # as the visitor left it — rows in the table, mutations still in the outbox.
    # Idempotent, because MigrationContext records the version it ran: pressing
    # this twice is a no-op, and so is every later boot.
    def create
      Release.ship
      redirect_to migrate_root_path
    end

    # Roll the local database back to v1 so the demo can be watched again. The
    # rows stay; only the column v2 added goes away.
    def destroy
      Release.roll_back
      redirect_to migrate_root_path
    end
  end
end
