require "test_helper"

class SyncableWidget < ActiveRecord::Base
  self.table_name = "items"
  include InstantRecord::Syncable
end

class PlainWidget < ActiveRecord::Base
  self.table_name = "items"
end

class InstantRecordTest < Minitest::Test
  def test_version_is_defined
    refute_nil InstantRecord::VERSION
  end

  def test_explicit_allowlist_wins_when_registered
    model = Class.new { def self.name = "Widget" }
    InstantRecord.sync(model)
    assert_equal [model], InstantRecord.synced_models
    assert_equal model, InstantRecord.synced_model("Widget")
    assert_nil InstantRecord.synced_model("SyncableWidget"), "allowlist restricts syncing to registered models"
  ensure
    InstantRecord.sync
  end

  def test_synced_model_falls_back_to_any_syncable_model_without_allowlist
    InstantRecord.sync
    assert_equal SyncableWidget, InstantRecord.synced_model("SyncableWidget")
  end

  def test_fallback_refuses_non_syncable_and_unknown_types
    InstantRecord.sync
    assert_nil InstantRecord.synced_model("PlainWidget"), "models without Syncable are not exposed"
    assert_nil InstantRecord.synced_model("NoSuchClass")
    assert_nil InstantRecord.synced_model("File"), "non-AR constants are not exposed"
  end
end
