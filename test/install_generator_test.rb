require "test_helper"
require "rails/generators/test_case"
require "prism"
require "tmpdir"
require "generators/instant_record/install/install_generator"

class InstallGeneratorTest < Rails::Generators::TestCase
  tests InstantRecord::Generators::InstallGenerator

  setup { self.destination_root = Dir.mktmpdir("install-generator") }
  teardown { FileUtils.remove_entry(destination_root) }

  test "writes toolchain config and starter initializer with clear next steps" do
    output = run_generator

    assert_file "config/instant_record_toolchain.env" do |content|
      assert_match(/SPINEL_HOME=/, content)
      assert_match(/ROUNDHOUSE_BIN=/, content)
      assert_match(/WEB_NODE_MODULES=/, content)
    end

    assert_file "config/initializers/instant_record.rb" do |content|
      assert Prism.parse(content).success?, "initializer should be valid Ruby"
      assert_match(/InstantRecord\.configure/, content)
      assert_match(/scope_from/, content)
      assert_match(/file_store/, content)
    end

    assert_includes output, "bin/rails db:migrate"
    assert_includes output, "bin/rails instant_record:doctor"
    assert_includes output, "bin/rails instant_record:compile"
  end

  test "preserves existing config files when run with --skip" do
    FileUtils.mkdir_p(File.join(destination_root, "config/initializers"))
    File.write(File.join(destination_root, "config/instant_record_toolchain.env"), "TOOLS=/custom\n")
    File.write(File.join(destination_root, "config/initializers/instant_record.rb"), "# mine\n")

    run_generator %w[--skip]

    assert_file "config/instant_record_toolchain.env", "TOOLS=/custom\n"
    assert_file "config/initializers/instant_record.rb", "# mine\n"
  end
end
