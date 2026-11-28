# frozen_string_literal: true

require "test_helper"
require "rbconfig"
require "tmpdir"
require "instant_record/compiler"

class CompilerRunnerManifestTest < Minitest::Test
  BuildError = InstantRecord::Compiler::BuildError
  Runner = InstantRecord::Compiler::Runner
  Manifest = InstantRecord::Compiler::Manifest

  # --- Compiler::Runner ---

  def test_runner_rejects_empty_command
    Dir.mktmpdir do |dir|
      runner = Runner.new(build_dir: dir)

      [[], nil].each do |empty_args|
        err = assert_raises(ArgumentError) { runner.run(empty_args) }
        assert_equal "command must not be empty", err.message
      end
    end
  end

  def test_runner_rejects_missing_or_non_directory_cwd_without_blaming_executable
    Dir.mktmpdir do |dir|
      runner = Runner.new(build_dir: dir)
      missing_cwd = File.join(dir, "does-not-exist")

      err = assert_raises(BuildError) { runner.run([RbConfig.ruby, "-e", "puts :ok"], cwd: missing_cwd) }
      assert_includes err.message, "working directory"
      assert_includes err.message, missing_cwd
      refute_includes err.message, "executable"

      file_cwd = File.join(dir, "plain.txt")
      File.write(file_cwd, "hello")
      err = assert_raises(BuildError) { runner.run([RbConfig.ruby, "-e", "puts :ok"], cwd: file_cwd) }
      assert_includes err.message, "working directory"
      assert_includes err.message, "is not a directory"
      assert_includes err.message, file_cwd
    end
  end

  def test_runner_rescues_enoent_and_eacces_with_clear_build_errors
    Dir.mktmpdir do |dir|
      runner = Runner.new(build_dir: dir)
      missing_exe = File.join(dir, "definitely-missing-binary")

      err = assert_raises(BuildError) { runner.run([missing_exe]) }
      assert_includes err.message, missing_exe
      assert_includes err.message, "not found"

      non_exec = File.join(dir, "not-executable.sh")
      File.write(non_exec, "#!/bin/sh\necho hi\n")
      File.chmod(0o644, non_exec)

      err = assert_raises(BuildError) { runner.run([non_exec]) }
      assert_includes err.message, non_exec
      assert_includes err.message, "not executable"
    end
  end

  def test_runner_executes_with_cwd_env_and_writes_binary_logs_safely
    Dir.mktmpdir do |dir|
      work_dir = File.join(dir, "work")
      build_dir = File.join(dir, "build")
      FileUtils.mkdir_p(work_dir)
      runner = Runner.new(build_dir: build_dir)

      out = runner.run(
        [RbConfig.ruby, "-e", "print Dir.pwd + '|' + ENV.fetch('RUNNER_TEST_VAR') + '|' + ENV.key?('RUNNER_UNSET_VAR').to_s"],
        cwd: work_dir,
        env: { RUNNER_TEST_VAR: 42, RUNNER_UNSET_VAR: nil }
      )
      assert_equal "#{File.realpath(work_dir)}|42|false", out

      # Non-UTF-8 / binary output on success writes raw bytes without encoding error.
      binary_script = "$stdout.binmode; $stdout.write(\"ok\\xFF\\xFE\\x00end\")"
      raw = runner.run([RbConfig.ruby, "-e", binary_script], log: "binary_ok.log")
      expected_bytes = "ok\xFF\xFE\x00end".b
      assert_equal expected_bytes, raw.b
      assert_equal expected_bytes, File.binread(File.join(build_dir, "binary_ok.log"))

      # Non-UTF-8 / binary output on failure writes raw log, filters warning/--rbs lines, and tails cleanly.
      fail_script_path = File.join(work_dir, "fail_script.rb")
      File.write(fail_script_path, <<~RUBY)
        $stdout.binmode
        $stdout.write("warning: noisy line\\n")
        $stdout.write("flag --rbs skipped\\n")
        $stdout.write("fatal \\xFF\\xFE detail\\n")
        exit 1
      RUBY
      err = assert_raises(BuildError) do
        runner.run([RbConfig.ruby, fail_script_path], log: "binary_fail.log")
      end
      assert_includes err.message, File.join(build_dir, "binary_fail.log")
      assert_includes err.message, "fatal"
      assert_includes err.message, "detail"
      refute_includes err.message, "noisy line"
      refute_includes err.message, "--rbs"
      assert_includes File.binread(File.join(build_dir, "binary_fail.log")), "fatal \xFF\xFE detail".b

      # Failure without log omits "(see ...)" and truncates output tail to 1500 chars.
      long_fail_path = File.join(work_dir, "long_fail.rb")
      File.write(long_fail_path, "print('x' * 2000 + 'END_MARKER'); exit 1\n")
      err = assert_raises(BuildError) { runner.run([RbConfig.ruby, long_fail_path]) }
      refute_includes err.message, "(see "
      assert_includes err.message, "END_MARKER"
      tail = err.message.split("\n", 2).last
      assert_equal 1500, tail.length
    end
  end

  # --- Compiler::Manifest.from_json / read ---

  def test_manifest_from_json_validates_syntax_and_object_root
    manifest = Manifest.from_json(JSON.generate(
      schema_version: 1,
      mode: "island",
      island: "tasks",
      models: [{ name: "Task", sync_window: { limit: 10 }, sync_scope: { column: "org_id" } }]
    ))
    assert_equal 1, manifest.schema_version
    assert manifest.island?
    assert_equal "tasks", manifest.island
    assert_equal %w[Task], manifest.synced_model_names
    assert_equal({ "Task" => { "limit" => 10 } }, manifest.sync_windows)
    assert_equal({ "Task" => { "column" => "org_id" } }, manifest.sync_scopes)

    ["{broken", ""].each do |bad_json|
      err = assert_raises(BuildError) { Manifest.from_json(bad_json) }
      assert_match(/\AInvalid manifest JSON:/, err.message)
    end

    ["[]", "\"string\"", "123", "true", "null"].each do |non_object|
      err = assert_raises(BuildError) { Manifest.from_json(non_object) }
      assert_equal "Manifest JSON must be a JSON object", err.message
    end

    Dir.mktmpdir do |dir|
      path = File.join(dir, Manifest::FILENAME)
      File.write(path, "[1, 2]")
      err = assert_raises(BuildError) { Manifest.read(path) }
      assert_equal "Manifest JSON must be a JSON object", err.message
    end
  end

  # --- Compiler::Manifest.load_config ---

  def test_load_config_handles_missing_and_empty_config_and_rejects_psych_exceptions
    Dir.mktmpdir do |dir|
      assert_equal({ include: Manifest.empty_includes, server_routes: [] }, Manifest.load_config(dir))

      config_path = File.join(dir, Manifest::CONFIG_FILE)
      FileUtils.mkdir_p(File.dirname(config_path))

      # Empty / comment-only YAML file returns empty overrides.
      File.write(config_path, "# comment only\n")
      assert_equal({ include: Manifest.empty_includes, server_routes: [] }, Manifest.load_config(dir))

      # Non-mapping root (including false and arrays) raises BuildError.
      ["- a\n- b\n", "false\n", "plain_scalar\n"].each do |yaml|
        File.write(config_path, yaml)
        err = assert_raises(BuildError) { Manifest.load_config(dir) }
        assert_includes err.message, "must be a YAML mapping"
      end

      # Psych::SyntaxError
      File.write(config_path, "include: [unterminated\n")
      err = assert_raises(BuildError) { Manifest.load_config(dir) }
      assert_match(/\AInvalid YAML in #{Regexp.escape(Manifest::CONFIG_FILE)}:/, err.message)

      # Psych::DisallowedClass
      File.write(config_path, "include: !ruby/object:Object {}\n")
      err = assert_raises(BuildError) { Manifest.load_config(dir) }
      assert_match(/\AInvalid YAML in #{Regexp.escape(Manifest::CONFIG_FILE)}:/, err.message)

      # Psych::BadAlias
      File.write(config_path, "include: *undefined_anchor\n")
      err = assert_raises(BuildError) { Manifest.load_config(dir) }
      assert_match(/\AInvalid YAML in #{Regexp.escape(Manifest::CONFIG_FILE)}:/, err.message)
    end
  end

  def test_load_config_supports_string_and_symbol_islands_and_validates_shapes
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, Manifest::CONFIG_FILE)
      FileUtils.mkdir_p(File.dirname(config_path))

      # Symbol :islands key and symbol island name work and merge with top-level config.
      File.write(config_path, <<~YAML)
        include:
          models:
            - SharedModel
        :islands:
          :tasks:
            include:
              models:
                - Task
            server_routes:
              - POST /tasks/export
      YAML

      loaded = Manifest.load_config(dir, island: "tasks")
      assert_equal %w[SharedModel Task], loaded[:include]["models"]
      assert_equal [["POST", "/tasks/export"]], loaded[:server_routes].map { |r| [r["method"], r["path"]] }

      # Empty islands section (nil) and empty island entry (nil) are permitted.
      File.write(config_path, "islands:\n")
      assert_equal({ include: Manifest.empty_includes, server_routes: [] }, Manifest.load_config(dir, island: :tasks))

      File.write(config_path, "islands:\n  tasks:\n")
      assert_equal({ include: Manifest.empty_includes, server_routes: [] }, Manifest.load_config(dir, island: :tasks))

      # Non-Hash islands (including false) raise BuildError for both string and symbol keys.
      [
        "islands: false\n",
        "islands:\n  - tasks\n",
        ":islands: false\n",
        ":islands: invalid\n"
      ].each do |yaml|
        File.write(config_path, yaml)
        err = assert_raises(BuildError) { Manifest.load_config(dir, island: :tasks) }
        assert_includes err.message, "islands must be a YAML mapping", "yaml=#{yaml.inspect}"
      end

      # Non-Hash requested island entry (including false) raises BuildError for both string and symbol keys.
      [
        "islands:\n  tasks: false\n",
        "islands:\n  tasks:\n    - Task\n",
        "islands:\n  :tasks: false\n",
        ":islands:\n  :tasks: nope\n"
      ].each do |yaml|
        File.write(config_path, yaml)
        err = assert_raises(BuildError) { Manifest.load_config(dir, island: :tasks) }
        assert_includes err.message, "islands.tasks must be a YAML mapping", "yaml=#{yaml.inspect}"
      end
    end
  end

  # --- Compiler::Manifest.normalize_overrides ---

  def test_normalize_overrides_rejects_non_hash_include_while_preserving_existing_forms
    # nil and non-Hash raw stay empty
    assert_equal({ include: Manifest.empty_includes, server_routes: [] }, Manifest.normalize_overrides(nil))
    assert_equal({ include: Manifest.empty_includes, server_routes: [] }, Manifest.normalize_overrides({}))

    # Explicit nil include stays valid, and top-level include keys continue to work
    assert_equal({ include: Manifest.empty_includes, server_routes: [] }, Manifest.normalize_overrides(include: nil))
    assert_equal %w[Task], Manifest.normalize_overrides(models: [:Task])[:include]["models"]
    assert_equal %w[Task], Manifest.normalize_overrides("include" => nil, "models" => ["Task"])[:include]["models"]

    # Non-nil, non-Hash explicit include (string or symbol key, including false) raises BuildError
    [
      { include: ["Task"] },
      { "include" => ["Task"] },
      { include: "Task" },
      { "include" => "Task" },
      { include: false },
      { "include" => false },
      { include: 123 }
    ].each do |bad|
      err = assert_raises(BuildError) { Manifest.normalize_overrides(bad) }
      assert_includes err.message, "include overrides must be a mapping", "bad=#{bad.inspect}"
    end
  end
end
