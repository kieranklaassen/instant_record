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

  # An app path on the authoritative server, for the rare action that must not be
  # served locally. Same expression in both runtimes: on the server the base is
  # empty and the marker is ignored.
  def test_server_url_is_same_origin_for_the_default_endpoint
    assert_equal "/slack/reset?instant_record_network=1", InstantRecord.server_url("/slack/reset")
  end

  def test_server_url_keeps_a_cross_origin_endpoints_host
    with_endpoint("http://localhost:3000/instant_record") do
      assert_equal "http://localhost:3000/slack/reset?instant_record_network=1",
        InstantRecord.server_url("/slack/reset")
    end
  end

  # The mount is configurable, so the strip has to read it rather than assume the
  # default. Hand-rolled copies of this in app code all stripped "/instant_record"
  # literally and broke the moment the mount moved.
  def test_server_url_follows_a_customised_mount_path
    with_mount_path("/sync") do
      with_endpoint("http://localhost:3000/sync") do
        assert_equal "http://localhost:3000/receipts/probe?instant_record_network=1",
          InstantRecord.server_url("/receipts/probe")
      end
    end
  end

  private

  def with_endpoint(endpoint)
    was = InstantRecord.config.endpoint
    InstantRecord.config.endpoint = endpoint
    yield
  ensure
    InstantRecord.config.endpoint = was
  end

  # The mount path lives in Rails config, which a plain-AR test process has none
  # of; the gem falls back to the default without it.
  def with_mount_path(path)
    config = Struct.new(:instant_record).new(Struct.new(:mount_path).new(path))
    application = Object.new
    application.define_singleton_method(:config) { config }
    rails = Module.new
    rails.define_singleton_method(:application) { application }
    Object.const_set(:Rails, rails)
    yield
  ensure
    Object.send(:remove_const, :Rails)
  end
end
