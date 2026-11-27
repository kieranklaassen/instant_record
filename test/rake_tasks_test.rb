require "test_helper"
require "rake"
require "json"
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

  test "instant_record:mcp --build builds the native host with options build_native takes" do
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      toolchain = File.join(dir, "toolchain.env")
      File.write(toolchain, "TOOLS=#{dir}\n")
      host_dir = File.join(dir, "tmp/instant_record/compiled/.build-native")

      # The real build_native runs; only the compile behind it and the host's process are left out.
      out, status = run_rake_task("instant_record:mcp", root: dir, toolchain: toolchain, arguments: %w[-- --build models], prepare: <<~RUBY)
        require "instant_record/mcp"

        InstantRecord::Compiler::NativeBuild.define_method(:run) do
          $stdout.puts "build output on stdout" if @out.equal?($stdout)
          @build_dir
        end
        InstantRecord::Mcp::Runtime.define_singleton_method(:new) do |host_binary:, **|
          Struct.new(:list_models, :close).new({ host: host_binary })
        end
      RUBY

      assert status.success?, "expected the host to be built:\n#{out}"
      assert_equal({ "host" => File.join(host_dir, "host") }, JSON.parse(out))
    end
  end

  test "instant_record:replay reads a flag before a rake argument before the environment before a positional wasm" do
    env = { "WASM" => "env.wasm", "TRACE" => "env.irtrace", "DB" => "env.db", "MAX_STEPS" => "9" }
    cases = {
      "a flag wins over a rake argument" =>
        [%w[--wasm flag.wasm], %w[rake.irtrace rake.wasm], env, { trace_path: "rake.irtrace", wasm_path: "flag.wasm" }],
      "a flag wins over the environment" =>
        [%w[--db flag.db --max-steps 3], [], env, { db_path: "flag.db", max_steps: "3" }],
      "a rake argument wins over the environment" =>
        [%w[pos.irtrace pos.wasm], %w[rake.irtrace rake.wasm], env, { trace_path: "rake.irtrace", wasm_path: "rake.wasm" }],
      "the environment's wasm wins over a positional one, its trace does not" =>
        [%w[pos.irtrace pos.wasm], [], env, { trace_path: "pos.irtrace", wasm_path: "env.wasm" }],
      "the environment is read when nothing else is given" =>
        [[], [], env, { trace_path: "env.irtrace", wasm_path: "env.wasm", db_path: "env.db", max_steps: "9" }],
      "a positional wasm is read last" =>
        [%w[pos.irtrace pos.wasm], [], {}, { trace_path: "pos.irtrace", wasm_path: "pos.wasm" }],
      "a value flag at the end is ignored" =>
        [%w[pos.irtrace --json --wasm], [], env, { trace_path: "pos.irtrace", wasm_path: "env.wasm", json: true }],
      "a value flag takes a following argument that looks like a flag" =>
        [%w[pos.irtrace --wasm --json], [], {}, { trace_path: "pos.irtrace", wasm_path: "--json", json: false }]
    }

    Dir.mktmpdir do |dir|
      out, status = run_rake_task("instant_record:replay", root: dir, toolchain: File.join(dir, "toolchain.env"), prepare: <<~RUBY)
        require "instant_record/trace"

        InstantRecord::Trace.define_singleton_method(:replay) do |**options|
          $replayed = options
          InstantRecord::Trace::Replayer::Result.new(ok: true, status: 0, stdout: "", stderr: "")
        end
        replayed = JSON.parse(#{JSON.generate(cases.values).inspect}).map do |argv, rake_args, env|
          ARGV.replace(["instant_record:replay", *argv])
          %w[TRACE WASM DB JSON MAX_STEPS].each { |name| ENV[name] = env[name] }
          Rake::Task["instant_record:replay"].reenable
          Rake::Task["instant_record:replay"].invoke(*rake_args)
          $replayed
        end
        puts JSON.generate(replayed)
        exit
      RUBY

      assert status.success?, out
      replayed = JSON.parse(out, symbolize_names: true)
      assert_equal cases.size, replayed.size
      cases.each_with_index do |(name, (_argv, _rake_args, _env, expected)), index|
        assert_equal expected, replayed[index].slice(*expected.keys), name
      end
    end
  end

  private

  def run_rake_task(task_name, root:, toolchain:, stub_build_error: nil, prepare: nil, arguments: [])
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
      #{prepare}
      Rake::Task[#{task_name.inspect}].invoke
    RUBY

    Open3.capture2e({ "INSTANT_RECORD_TOOLCHAIN" => toolchain }, RbConfig.ruby, "-e", script, task_name, *arguments)
  end
end
