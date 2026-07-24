require "test_helper"

# The browser VM starts at "/" while the app is mounted at "/rails", so a
# relative migration path resolves to nothing there and `prepare_all` silently
# finds no pending migrations — leaving a returning client on whatever schema
# its local database was created with. InstantRecord::LocalSchema catches such a
# database up using these paths instead of the relative default; this pins the
# property that makes them safe to use from any working directory.
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
