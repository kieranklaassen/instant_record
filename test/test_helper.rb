require "minitest/autorun"
require "active_record"
require "instant_record"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")

# MutationApplier parses incoming stamps through Time.zone, which Rails sets and
# a plain-AR test process does not.
require "active_support/core_ext/time"
Time.zone = "UTC"

# App-side models are engine-autoloaded under Rails; plain-AR tests load them
# explicitly so server-side change logging is exercised without a Rails boot.
require File.expand_path("../app/models/instant_record/change", __dir__)
require File.expand_path("../app/models/instant_record/applied_mutation", __dir__)
require File.expand_path("../app/models/instant_record/mutation_applier", __dir__)

# The gem's own tables come from its real migrations, so tests can't drift
# from what ships (and every test file works standalone).
ActiveRecord::MigrationContext.new(File.expand_path("../db/migrate", __dir__)).migrate

# One shared table backs all fake syncable models.
ActiveRecord::Schema.define do
  create_table :items, id: :string, force: true do |t|
    t.string :title
    t.string :state
    t.integer :server_version, null: false, default: 0
    t.string :sync_state, null: false, default: "synced"
    t.timestamps
  end
end

module InstantRecordTestHelpers
  # Runtime stubbing, defined once here: Syncable guards its callbacks at
  # call time, so swapping browser? for the duration of a block is all any
  # test needs.
  def with_runtime(browser:, &block)
    InstantRecord.singleton_class.class_eval do
      alias_method :original_browser?, :browser?
      define_method(:browser?) { browser }
    end
    block.call
  ensure
    InstantRecord.singleton_class.class_eval do
      remove_method :browser?
      alias_method :browser?, :original_browser?
      remove_method :original_browser?
    end
  end

  def in_browser(&block) = with_runtime(browser: true, &block)
  def on_server(&block) = with_runtime(browser: false, &block)

  # A fresh anonymous syncable model backed by the shared items table.
  def syncable_model(name = "Item", &body)
    Class.new(ActiveRecord::Base) do
      self.table_name = "items"
      define_singleton_method(:name) { name }
      include InstantRecord::Syncable
      class_eval(&body) if body
    end
  end

  def reset_instant_record_tables!
    ActiveRecord::Base.connection.execute("DELETE FROM items")
    InstantRecord::OutboxMutation.delete_all
    InstantRecord::SyncMetadata.delete_all
    InstantRecord::Change.delete_all
    InstantRecord::AppliedMutation.delete_all
  end
end

Minitest::Test.include(InstantRecordTestHelpers)
