require "test_helper"

class RuntimeScopedTest < Minitest::Test
  def build_class
    Class.new do
      extend InstantRecord::RuntimeScoped

      server_only do
        def self.server_rule = "server"
      end

      browser_only do
        def self.browser_rule = "browser"
      end
    end
  end

  def test_server_runtime_gets_only_server_blocks
    klass = on_server { build_class }

    assert_equal "server", klass.server_rule
    refute_respond_to klass, :browser_rule
  end

  def test_browser_runtime_gets_only_browser_blocks
    klass = in_browser { build_class }

    assert_equal "browser", klass.browser_rule
    refute_respond_to klass, :server_rule
  end

  def test_syncable_models_get_the_dsl_automatically
    model = syncable_model("Widget")

    assert_respond_to model, :server_only
    assert_respond_to model, :browser_only
  end
end
