require "test_helper"

class InstantRecordTest < Minitest::Test
  def test_version_is_defined
    refute_nil InstantRecord::VERSION
  end

  def test_sync_registers_models
    model = Class.new { def self.name = "Widget" }
    InstantRecord.sync(model)
    assert_equal [model], InstantRecord.synced_models
    assert_equal model, InstantRecord.synced_model("Widget")
    assert_nil InstantRecord.synced_model("Unknown")
  ensure
    InstantRecord.sync
  end
end
