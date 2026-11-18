require "test_helper"

# The compiled migration plan uses the host app’s absolute migration paths.
class MigrationPathsTest < ActiveSupport::TestCase
  def paths
    Rails.application.config.paths["db/migrate"].existent
  end

  test "the app's migration paths are absolute and include the gem's own" do
    assert paths.any?, "no migration paths configured"
    paths.each { |path| assert path.start_with?("/"), "#{path} is not absolute" }
    assert paths.any? { |path| path.include?("instant_record") },
      "the engine's migrations are not on the path, so the browser cannot apply them"
  end

  test "those paths find migrations from a working directory that is not Rails.root" do
    Dir.chdir("/") do
      found = ActiveRecord::MigrationContext.new(paths).migrations
      assert found.any?, "absolute paths found no migrations from /"
    end
  end

  # The failure this guards against: the relative default that Rails ships is
  # only correct while the working directory happens to be Rails.root.
  test "the relative default finds nothing from a working directory that is not Rails.root" do
    Dir.chdir("/") do
      assert_empty ActiveRecord::MigrationContext.new("db/migrate").migrations
    end
  end
end
