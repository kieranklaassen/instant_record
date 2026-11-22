require "test_helper"
require "rake"
require "open3"
require "tmpdir"

class RakeTasksTest < ActiveSupport::TestCase
  RAKE_FILE = File.expand_path("../lib/tasks/instant_record.rake", __dir__)

  test "instant_record:compile and instant_record:native abort cleanly when toolchain file is missing" do
    Dir.mktmpdir do |dir|
      missing = File.join(dir, "no_such_toolchain.env")
      %w[instant_record:compile instant_record:native].each do |task_name|
        out, status = run_rake_task(task_name, root: dir, toolchain: missing)
        refute status.success?, "expected #{task_name} to fail"
        assert_includes out, "No toolchain file at #{missing}"
        assert_includes out, "instant_record:install"
      end
    end
  end

  test "instant_record:compile aborts cleanly on Compiler::BuildError" do
    Dir.mktmpdir do |dir|
      toolchain = File.join(dir, "toolchain.env")
      File.write(toolchain, "TOOLS=#{dir}\n")
      out, status = run_rake_task("instant_record:compile", root: dir, toolchain: toolchain, stub_build_error: "simulated compiler failure")
      refute status.success?
      assert_includes out, "simulated compiler failure"
      refute_includes out, "from #{RAKE_FILE}"
    end
  end

  private

  def run_rake_task(task_name, root:, toolchain:, stub_build_error: nil)
    script = <<~RUBY
      $LOAD_PATH.unshift(#{File.expand_path("../lib", __dir__).inspect})
      require "rake"
      require "pathname"
      require "active_support/lazy_load_hooks"
      require "active_support/ordered_options"
      require "instant_record"
      require "instant_record/compiler"

      module Rails
        def self.root = Pathname(#{root.inspect})
        def self.application
          @application ||= begin
            cfg = Struct.new(:instant_record, :paths).new(
              ActiveSupport::OrderedOptions.new.tap { |o| o.mount_path = "/instant_record" },
              { "db/migrate" => Struct.new(:existent).new([]) }
            )
            Struct.new(:config) do
              def eager_load! = nil
            end.new(cfg)
          end
        end
      end

      Rake::Task.define_task(:environment)
      load #{RAKE_FILE.inspect}
      #{stub_build_error ? "InstantRecord::Compiler.define_singleton_method(:build) { |**| raise InstantRecord::Compiler::BuildError, #{stub_build_error.inspect} }" : ""}
      Rake::Task[#{task_name.inspect}].invoke
    RUBY

    Open3.capture2e({ "INSTANT_RECORD_TOOLCHAIN" => toolchain }, RbConfig.ruby, "-e", script)
  end
end
