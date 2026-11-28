require "test_helper"
require "instant_record/compiler/fts5_smoke"
require "fileutils"
require "tmpdir"

class Fts5SmokeTest < ActiveSupport::TestCase
  Fts5Smoke = InstantRecord::Compiler::Fts5Smoke
  Toolchain = InstantRecord::Compiler::Toolchain
  Runner = InstantRecord::Compiler::Runner
  BuildError = InstantRecord::Compiler::BuildError

  FakeRunner = Struct.new(:build_dir, :calls, :handler) do
    def run(args, **_opts)
      calls << args
      handler ? handler.call(args) : ""
    end
  end

  test "initialize accepts native and wasm targets and rejects nil, empty, and unknown targets" do
    tc = Toolchain.new(path: "/opt/toolchain.env", values: {})

    assert_instance_of Fts5Smoke, Fts5Smoke.new(toolchain: tc, target: :native)
    assert_instance_of Fts5Smoke, Fts5Smoke.new(toolchain: tc, target: "native")
    assert_instance_of Fts5Smoke, Fts5Smoke.new(toolchain: tc, target: :wasm)
    assert_instance_of Fts5Smoke, Fts5Smoke.new(toolchain: tc, target: "wasm")

    [nil, "", :bogus, "ios", 123].each do |invalid|
      err = assert_raises(ArgumentError) { Fts5Smoke.new(toolchain: tc, target: invalid) }
      assert_match(/Unknown FTS5 smoke target:/, err.message)
    end
  end

  test "cached_sqlite_object raises BuildError when sqlite3.c is missing" do
    Dir.mktmpdir do |dir|
      tc = Toolchain.new(path: File.join(dir, "toolchain.env"), values: { "CACHE" => File.join(dir, "cache") })
      smoke = Fts5Smoke.new(toolchain: tc, target: :native)
      runner = FakeRunner.new(dir, [], nil)

      err = assert_raises(BuildError) do
        smoke.send(
          :cached_sqlite_object,
          runner: runner,
          key_prefix: "fts5-native",
          cc: "cc",
          cflags: ["-O2"],
          sqlite_src: dir
        )
      end
      assert_match(/Missing SQLite amalgamation source:/, err.message)
      assert_empty runner.calls
    end
  end

  test "cached_sqlite_object skips compilation on cache hit" do
    Dir.mktmpdir do |dir|
      sqlite_src = File.join(dir, "sqlite")
      cache_dir = File.join(dir, "cache")
      FileUtils.mkdir_p([sqlite_src, cache_dir])
      File.write(File.join(sqlite_src, "sqlite3.c"), "/* sqlite */\n")

      tc = Toolchain.new(path: File.join(dir, "toolchain.env"), values: { "CACHE" => cache_dir })
      smoke = Fts5Smoke.new(toolchain: tc, target: :native)

      first_runner = FakeRunner.new(dir, [], ->(args) { File.write(args.last, "OBJECT") })
      obj = smoke.send(
        :cached_sqlite_object,
        runner: first_runner,
        key_prefix: "fts5-native",
        cc: "cc",
        cflags: ["-O2"],
        sqlite_src: sqlite_src
      )
      assert File.file?(obj)
      assert_equal 1, first_runner.calls.size

      second_runner = FakeRunner.new(dir, [], ->(*) { flunk "expected cache hit to skip compilation" })
      cached = smoke.send(
        :cached_sqlite_object,
        runner: second_runner,
        key_prefix: "fts5-native",
        cc: "cc",
        cflags: ["-O2"],
        sqlite_src: sqlite_src
      )
      assert_equal obj, cached
      assert_empty second_runner.calls
    end
  end

  test "cached_sqlite_object uses unique temp names and cleans up partial temp objects on failure" do
    Dir.mktmpdir do |dir|
      sqlite_src = File.join(dir, "sqlite")
      cache_dir = File.join(dir, "cache")
      FileUtils.mkdir_p([sqlite_src, cache_dir])
      File.write(File.join(sqlite_src, "sqlite3.c"), "/* sqlite */\n")

      tc = Toolchain.new(path: File.join(dir, "toolchain.env"), values: { "CACHE" => cache_dir })
      smoke = Fts5Smoke.new(toolchain: tc, target: :native)

      temp_paths = []
      failing_runner = FakeRunner.new(dir, [], ->(args) {
        tmp_out = args.last
        temp_paths << tmp_out
        File.write(tmp_out, "PARTIAL")
        raise BuildError, "compile failed"
      })

      2.times do
        assert_raises(BuildError) do
          smoke.send(
            :cached_sqlite_object,
            runner: failing_runner,
            key_prefix: "fts5-native",
            cc: "cc",
            cflags: ["-O2"],
            sqlite_src: sqlite_src
          )
        end
      end

      assert_equal 2, temp_paths.size
      refute_equal temp_paths[0], temp_paths[1]
      temp_paths.each do |path|
        assert_match(/sqlite3\.#{Process.pid}\.[0-9a-f]{12}\.o\z/, File.basename(path))
        refute File.exist?(path), "expected temp object #{path} to be cleaned up"
      end
      assert_empty Dir.glob(File.join(cache_dir, "**/*.o"))
    end
  end

  test "cached_sqlite_object cleans up temp object when rename fails and falls back to build_dir when CACHE is unset" do
    Dir.mktmpdir do |dir|
      sqlite_src = File.join(dir, "sqlite")
      build_dir = File.join(dir, "build")
      FileUtils.mkdir_p([sqlite_src, build_dir])
      File.write(File.join(sqlite_src, "sqlite3.c"), "/* sqlite */\n")

      tc = Toolchain.new(path: File.join(dir, "toolchain.env"), values: {})
      smoke = Fts5Smoke.new(toolchain: tc, target: :native)

      written_tmp = nil
      runner = FakeRunner.new(build_dir, [], ->(args) {
        written_tmp = args.last
        File.write(written_tmp, "OBJ")
      })

      stub_singleton(File, :rename, ->(*_args) { raise Errno::EXDEV, "cross-device link" }) do
        assert_raises(Errno::EXDEV) do
          smoke.send(
            :cached_sqlite_object,
            runner: runner,
            key_prefix: "fts5-native",
            cc: "cc",
            cflags: ["-O2"],
            sqlite_src: sqlite_src
          )
        end
      end

      assert written_tmp.start_with?(build_dir)
      refute File.exist?(written_tmp)

      obj = smoke.send(
        :cached_sqlite_object,
        runner: runner,
        key_prefix: "fts5-native",
        cc: "cc",
        cflags: ["-O2"],
        sqlite_src: sqlite_src
      )
      assert_equal File.join(build_dir, "sqlite3.o"), obj
      assert File.file?(obj)
    end
  end

  test "parse_result validates JSON shape, ok flag, and malformed output" do
    tc = Toolchain.new(path: "/opt/toolchain.env", values: {})
    smoke = Fts5Smoke.new(toolchain: tc, target: :wasm)

    ok_result = smoke.send(:parse_result, %({"ok":true,"matches":2,"prefix":1,"phrase":"Native iOS"}\n))
    assert_equal({ ok: true, matches: 2, prefix: 1, phrase: "Native iOS", target: :wasm }, ok_result)

    err_false = assert_raises(BuildError) { smoke.send(:parse_result, %({"ok":false})) }
    assert_match(/FTS5 smoke test returned/, err_false.message)

    ["[1, 2, 3]", '"string"', "true", "null", "42"].each do |non_hash|
      err = assert_raises(BuildError) { smoke.send(:parse_result, non_hash) }
      assert_match(/FTS5 smoke test returned/, err.message)
    end

    ["not json", "", nil].each do |malformed|
      err = assert_raises(BuildError) { smoke.send(:parse_result, malformed) }
      assert_match(/FTS5 smoke test produced invalid JSON/, err.message)
    end
  end

  test "run_native compiles sqlite3.c and smoke.c and parses smoke binary output without a C compiler" do
    Dir.mktmpdir do |dir|
      sqlite_src = File.join(dir, "sqlite")
      cache_dir = File.join(dir, "cache")
      FileUtils.mkdir_p(sqlite_src)
      File.write(File.join(sqlite_src, "sqlite3.c"), "/* sqlite */\n")

      tc = Toolchain.new(
        path: File.join(dir, "toolchain.env"),
        values: { "SQLITE_SRC" => sqlite_src, "CACHE" => cache_dir }
      )

      recorded = []
      smoke_c_present = false
      fake_runner_factory = ->(build_dir:) {
        FakeRunner.new(build_dir, recorded, ->(args) {
          if args.include?("-c")
            File.write(args.last, "OBJ")
            ""
          elsif args.include?("-o")
            smoke_c_present = File.file?(File.join(build_dir, "smoke.c"))
            File.write(args.last, "BIN")
            ""
          else
            %({"ok":true,"matches":2,"prefix":1,"phrase":"Native iOS"}\n)
          end
        })
      }

      with_env("CC" => "stub-cc") do
        stub_singleton(Runner, :new, fake_runner_factory) do
          result = Fts5Smoke.run(toolchain: tc, target: :native)
          assert_equal({ ok: true, matches: 2, prefix: 1, phrase: "Native iOS", target: :native }, result)
        end
      end

      assert smoke_c_present
      assert_equal 3, recorded.size
      assert_equal "stub-cc", recorded[0].first
      assert_includes recorded[0], "-DSQLITE_ENABLE_FTS5"
      assert_includes recorded[1], "-I#{sqlite_src}"
      assert_equal 1, recorded[2].size
      assert_match(/fts5_smoke\z/, recorded[2].first)
    end
  end

  test "run_wasm compiles with WASI flags, writes WASI runner script, and executes node" do
    Dir.mktmpdir do |dir|
      sqlite_src = File.join(dir, "sqlite")
      wasi_sdk = File.join(dir, "wasi-sdk")
      cache_dir = File.join(dir, "cache")
      FileUtils.mkdir_p(sqlite_src)
      File.write(File.join(sqlite_src, "sqlite3.c"), "/* sqlite */\n")

      tc = Toolchain.new(
        path: File.join(dir, "toolchain.env"),
        values: { "SQLITE_SRC" => sqlite_src, "WASI_SDK" => wasi_sdk, "CACHE" => cache_dir }
      )

      recorded = []
      js_content = nil
      fake_runner_factory = ->(build_dir:) {
        FakeRunner.new(build_dir, recorded, ->(args) {
          if args.include?("-c")
            File.write(args.last, "WASM_OBJ")
            ""
          elsif args.include?("-o")
            js_path = File.join(build_dir, "run_wasi.mjs")
            js_content = File.read(js_path)
            File.write(args.last, "WASM_BIN")
            ""
          else
            %({"ok":true,"matches":2,"prefix":1,"phrase":"Native iOS"}\n)
          end
        })
      }

      stub_singleton(Toolchain, :which, ->(cmd, **_opts) { cmd == "node" ? "/opt/bin/node" : nil }) do
        stub_singleton(Runner, :new, fake_runner_factory) do
          result = Fts5Smoke.run(toolchain: tc, target: :wasm)
          assert_equal({ ok: true, matches: 2, prefix: 1, phrase: "Native iOS", target: :wasm }, result)
        end
      end

      assert_equal 3, recorded.size
      assert_equal File.join(wasi_sdk, "bin/clang"), recorded[0].first
      assert_includes recorded[0], "-DSQLITE_ENABLE_FTS5"
      assert_includes recorded[1], "-lwasi-emulated-signal"
      assert_equal "/opt/bin/node", recorded[2][0]
      assert_equal "--no-warnings", recorded[2][1]
      assert_match(/node:wasi/, js_content)
    end
  end

  test "run_wasm raises BuildError when node is missing" do
    tc = Toolchain.new(
      path: "/opt/toolchain.env",
      values: { "SQLITE_SRC" => "/opt/sqlite", "WASI_SDK" => "/opt/wasi-sdk" }
    )

    stub_singleton(Toolchain, :which, ->(*) { nil }) do
      err = assert_raises(BuildError) { Fts5Smoke.run(toolchain: tc, target: :wasm) }
      assert_match(/node is required/, err.message)
    end
  end

  private

  def with_env(overrides)
    previous = overrides.keys.each_with_object({}) { |k, h| h[k] = ENV.key?(k) ? ENV[k] : :__unset__ }
    overrides.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    previous.each do |k, v|
      if v == :__unset__
        ENV.delete(k)
      else
        ENV[k] = v
      end
    end
  end

  def stub_singleton(target, method_name, replacement)
    singleton = target.singleton_class
    was_private = singleton.private_method_defined?(method_name, false)
    had_own_method = was_private || singleton.method_defined?(method_name, false)
    original = singleton.instance_method(method_name) if had_own_method
    singleton.remove_method(method_name) if had_own_method
    singleton.define_method(method_name, &replacement)
    yield
  ensure
    singleton.remove_method(method_name) if singleton.method_defined?(method_name, false) || singleton.private_method_defined?(method_name, false)
    if had_own_method
      singleton.define_method(method_name, original)
      singleton.private(method_name) if was_private
    end
  end
end
