require "test_helper"
require "instant_record/compiler/toolchain"
require "fileutils"
require "tmpdir"

class ToolchainTest < ActiveSupport::TestCase
  Toolchain = InstantRecord::Compiler::Toolchain
  BuildError = InstantRecord::Compiler::BuildError

  FakeStatus = Struct.new(:success?)
  FakeLint = Struct.new(:files_checked, :diagnostics, :rendered, keyword_init: true) do
    def ok? = diagnostics.empty?
    def to_s = rendered
  end

  test "Toolchain.load returns an existing Toolchain instance unchanged" do
    tc = Toolchain.new(path: "/opt/toolchain.env", values: { "TOOLS" => "/opt" })
    assert_same tc, Toolchain.load(tc)
  end

  test "Toolchain.load raises ArgumentError for a missing file" do
    error = assert_raises(ArgumentError) do
      Toolchain.load("/nonexistent/instant_record_toolchain.env")
    end
    assert_match(/Missing compiler toolchain file:/, error.message)
  end

  test "Toolchain.load ignores comments, blank lines, lines without equals, and empty keys" do
    Dir.mktmpdir do |dir|
      env_file = File.join(dir, "toolchain.env")
      File.write(env_file, <<~ENV)
        # leading comment

        NOT_AN_ASSIGNMENT
        =ignored_empty_key
          =also_ignored
        TOOLS=/opt/tools
        VALUE_WITH_EQUALS=a=b=c
      ENV

      tc = Toolchain.load(env_file)
      assert_equal({ "TOOLS" => "/opt/tools", "VALUE_WITH_EQUALS" => "a=b=c" }, tc.values)
    end
  end

  test "Toolchain.load expands $VAR and ${VAR} while preserving unknown references" do
    Dir.mktmpdir do |dir|
      env_file = File.join(dir, "toolchain.env")
      File.write(env_file, <<~ENV)
        TOOLS=/opt/tools
        TOOLS_CACHE=/var/cache
        SPINEL_HOME=$TOOLS/spinel
        BRACED=${TOOLS}/wasi
        BRACED_SUFFIX=${TOOLS}_extra/bin
        PREFIX_SAFE=$TOOLS_CACHE/builds
        UNKNOWN_PLAIN=$MISSING/path
        UNKNOWN_BRACED=${MISSING}/path
      ENV

      tc = Toolchain.load(env_file)
      assert_equal "/opt/tools/spinel", tc.fetch("SPINEL_HOME")
      assert_equal "/opt/tools/wasi", tc.fetch("BRACED")
      assert_equal "/opt/tools_extra/bin", tc.fetch("BRACED_SUFFIX")
      assert_equal "/var/cache/builds", tc.fetch("PREFIX_SAFE")
      assert_equal "$MISSING/path", tc.fetch("UNKNOWN_PLAIN")
      assert_equal "${MISSING}/path", tc.fetch("UNKNOWN_BRACED")
    end
  end

  test "bracket lookup, fetch, and join enforce required keys" do
    tc = Toolchain.new(
      path: "/opt/toolchain.env",
      values: { "SPINEL_HOME" => "/opt/spinel", "EMPTY" => "" }
    )

    assert_equal "/opt/spinel", tc["SPINEL_HOME"]
    assert_equal "/opt/spinel", tc[:SPINEL_HOME]
    assert_nil tc["MISSING"]

    assert_equal "/opt/spinel", tc.fetch("SPINEL_HOME")
    assert_equal "/opt/spinel/bin/spinel", tc.join("SPINEL_HOME", "bin", "spinel")

    missing_err = assert_raises(BuildError) { tc.fetch("MISSING") }
    assert_match(%r{Missing MISSING in /opt/toolchain\.env}, missing_err.message)

    empty_err = assert_raises(BuildError) { tc.fetch("EMPTY") }
    assert_match(%r{Missing EMPTY in /opt/toolchain\.env}, empty_err.message)

    assert_raises(BuildError) { tc.join("MISSING", "bin") }
  end

  test "Toolchain.which handles nil, empty, absolute, relative, PATH, extra_paths, non-executable, and directories" do
    assert_nil Toolchain.which(nil)
    assert_nil Toolchain.which("")

    Dir.mktmpdir do |dir|
      bin_dir = File.join(dir, "bin")
      extra_dir = File.join(dir, "extra")
      sub_dir = File.join(bin_dir, "subdir_cmd")
      FileUtils.mkdir_p([bin_dir, extra_dir, sub_dir])

      path_tool = make_executable(File.join(bin_dir, "my-tool"))
      extra_tool = make_executable(File.join(extra_dir, "extra-tool"))
      non_exec = File.join(bin_dir, "not-exec")
      File.write(non_exec, "#!/bin/sh\n")
      File.chmod(0o644, non_exec)

      assert_equal path_tool, Toolchain.which(path_tool)
      assert_nil Toolchain.which(non_exec)
      assert_nil Toolchain.which(bin_dir)
      assert_nil Toolchain.which(sub_dir)

      Dir.chdir(dir) do
        assert_equal "./bin/my-tool", Toolchain.which("./bin/my-tool")
        assert_nil Toolchain.which("./bin/subdir_cmd")
        assert_nil Toolchain.which("./bin/does-not-exist")
      end

      with_env("PATH" => bin_dir) do
        assert_equal path_tool, Toolchain.which("my-tool")
        assert_nil Toolchain.which("not-exec")
        assert_nil Toolchain.which("subdir_cmd")
        assert_nil Toolchain.which("extra-tool")
        assert_equal extra_tool, Toolchain.which("extra-tool", extra_paths: [extra_dir])
      end
    end
  end

  test "check_writable_dir accepts existing writable dirs and nested uncreated dirs, rejecting regular files and read-only dirs" do
    Dir.mktmpdir do |dir|
      existing = File.join(dir, "cache")
      FileUtils.mkdir_p(existing)
      nested = File.join(dir, "a/b/c/cache")
      regular_file = File.join(dir, "file_cache")
      File.write(regular_file, "not a directory\n")
      under_file = File.join(regular_file, "nested/cache")

      assert_equal :ok, cache_check_for(existing).status
      assert_equal existing, cache_check_for(existing).detail

      nested_check = cache_check_for(nested)
      assert_equal :ok, nested_check.status
      assert_equal nested, nested_check.detail

      file_check = cache_check_for(regular_file)
      assert_equal :missing, file_check.status
      assert_match(/not writable:/, file_check.detail)

      under_file_check = cache_check_for(under_file)
      assert_equal :missing, under_file_check.status

      unset_check = cache_check_for(nil)
      assert_equal :missing, unset_check.status
      assert_equal "not writable: CACHE", unset_check.detail

      empty_check = cache_check_for("")
      assert_equal :missing, empty_check.status
      assert_equal "not writable: CACHE", empty_check.detail

      unless Process.uid == 0
        readonly = File.join(dir, "readonly")
        FileUtils.mkdir_p(readonly)
        File.chmod(0o555, readonly)
        begin
          assert_equal :missing, cache_check_for(readonly).status
          assert_equal :missing, cache_check_for(File.join(readonly, "nested/cache")).status
        ensure
          File.chmod(0o755, readonly)
        end
      end
    end
  end

  test "doctor checks wasm, native, iphonesimulator, iphoneos, defaults nil target to wasm, and rejects unknown targets" do
    Dir.mktmpdir do |dir|
      env_values = build_complete_toolchain_layout(dir)
      bin_dir = env_values.delete("_BIN_DIR")
      tc = Toolchain.new(path: File.join(dir, "toolchain.env"), values: env_values)

      with_env("PATH" => bin_dir, "CC" => "fake-cc") do
        wasm = tc.doctor(target: :wasm)
        assert wasm.ok?, wasm.to_s
        assert_equal :wasm, wasm.target
        assert_equal(
          [
            "spinel", "spin", "roundhouse", "sqlite3.c", "CACHE",
            "spinel wasm-rt", "wasi clang", "wasi llvm-ar", "wasi llvm-strip",
            "npx", "WEB_NODE_MODULES", "RAILS_GEMS", "wasm-opt"
          ],
          wasm.checks.map(&:name)
        )
        assert_equal :optional, wasm.checks.find { |c| c.name == "wasm-opt" }.status

        defaulted = tc.doctor(target: nil)
        assert_equal :wasm, defaulted.target
        assert defaulted.ok?, defaulted.to_s

        native = tc.doctor(target: :native)
        assert native.ok?, native.to_s
        assert_equal :native, native.target
        assert_equal(
          ["spinel", "spin", "roundhouse", "sqlite3.c", "CACHE", "spinel rt", "fake-cc", "ar"],
          native.checks.map(&:name)
        )

        stub_singleton(Open3, :capture2e, ->(*args) {
          sdk = args[2]
          ["/SDKs/#{sdk}.sdk\n", FakeStatus.new(true)]
        }) do
          sim = tc.doctor(target: :iphonesimulator)
          assert sim.ok?, sim.to_s
          assert_equal :iphonesimulator, sim.target
          assert_equal(
            ["spinel", "spin", "roundhouse", "sqlite3.c", "CACHE", "spinel Makefile", "iphonesimulator SDK", "ar"],
            sim.checks.map(&:name)
          )
          assert_equal "/SDKs/iphonesimulator.sdk", sim.checks.find { |c| c.name == "iphonesimulator SDK" }.detail

          ios = tc.doctor(target: :iphoneos)
          assert ios.ok?, ios.to_s
          assert_equal :iphoneos, ios.target
          assert_equal "/SDKs/iphoneos.sdk", ios.checks.find { |c| c.name == "iphoneos SDK" }.detail
        end
      end

      err = assert_raises(ArgumentError) { tc.doctor(target: :android) }
      assert_equal "Unknown doctor target: android", err.message
    end
  end

  test "doctor resolves local web_dir node_modules fallback when WEB_NODE_MODULES is unset" do
    Dir.mktmpdir do |dir|
      env_values = build_complete_toolchain_layout(dir)
      bin_dir = env_values.delete("_BIN_DIR")
      env_values.delete("WEB_NODE_MODULES")
      web_dir = File.join(dir, "web")
      FileUtils.mkdir_p(File.join(web_dir, "node_modules"))
      tc = Toolchain.new(path: File.join(dir, "toolchain.env"), values: env_values)

      with_env("PATH" => bin_dir) do
        report = tc.doctor(target: :wasm, web_dir: web_dir)
        check = report.checks.find { |c| c.name == "WEB_NODE_MODULES" }
        assert_equal :ok, check.status
        assert_equal "#{File.join(web_dir, 'node_modules')} (local)", check.detail
      end
    end
  end

  test "check_xcode_sdk handles non-zero exit, empty output, and missing xcrun" do
    Dir.mktmpdir do |dir|
      env_values = build_complete_toolchain_layout(dir)
      bin_dir = env_values.delete("_BIN_DIR")
      tc = Toolchain.new(path: File.join(dir, "toolchain.env"), values: env_values)

      with_env("PATH" => bin_dir) do
        stub_singleton(Open3, :capture2e, ->(*) { ["xcode-select: error: no developer tools\n", FakeStatus.new(false)] }) do
          report = tc.doctor(target: :iphoneos)
          refute report.ok?
          sdk_check = report.checks.find { |c| c.name == "iphoneos SDK" }
          assert_equal :missing, sdk_check.status
          assert_equal "xcode-select: error: no developer tools", sdk_check.detail
        end

        stub_singleton(Open3, :capture2e, ->(*) { ["   \n", FakeStatus.new(false)] }) do
          sdk_check = tc.doctor(target: :iphoneos).checks.find { |c| c.name == "iphoneos SDK" }
          assert_equal :missing, sdk_check.status
          assert_equal "xcrun failed", sdk_check.detail
        end

        stub_singleton(Open3, :capture2e, ->(*) { ["", FakeStatus.new(true)] }) do
          sdk_check = tc.doctor(target: :iphoneos).checks.find { |c| c.name == "iphoneos SDK" }
          assert_equal :missing, sdk_check.status
          assert_equal "xcrun failed", sdk_check.detail
        end

        stub_singleton(Open3, :capture2e, ->(*) { raise Errno::ENOENT, "No such file or directory - xcrun" }) do
          sdk_check = tc.doctor(target: :iphonesimulator).checks.find { |c| c.name == "iphonesimulator SDK" }
          assert_equal :missing, sdk_check.status
          assert_equal "xcrun not found on PATH", sdk_check.detail
        end
      end
    end
  end

  test "Report#with_lint and Report#to_s format badges and lint output deterministically" do
    base_checks = [
      Toolchain::Check.new(name: "spinel", status: :ok, detail: "/opt/spinel"),
      Toolchain::Check.new(name: "wasm-opt", status: :optional, detail: "not on PATH"),
      Toolchain::Check.new(name: "schema", status: :error, detail: "out of date"),
      Toolchain::Check.new(name: "roundhouse", status: :missing, detail: "not found")
    ]
    report = Toolchain::Report.new(target: :wasm, path: "/opt/toolchain.env", checks: base_checks)

    expected_base = [
      "InstantRecord toolchain check (wasm) — /opt/toolchain.env",
      "  [OK      ] spinel             /opt/spinel",
      "  [OPTIONAL] wasm-opt           not on PATH",
      "  [ERROR   ] schema             out of date",
      "  [MISSING ] roundhouse         not found"
    ].join("\n")
    assert_equal expected_base, report.to_s
    refute report.ok?

    passing_report = Toolchain::Report.new(
      target: :wasm,
      path: "/opt/toolchain.env",
      checks: [
        Toolchain::Check.new(name: "spinel", status: :ok, detail: "/opt/spinel"),
        Toolchain::Check.new(name: "wasm-opt", status: :optional, detail: "optional")
      ]
    )
    ok_lint = FakeLint.new(files_checked: 5, diagnostics: [], rendered: "Static AOT lint passed (5 files checked).")
    with_ok_lint = passing_report.with_lint(ok_lint)

    assert with_ok_lint.ok?
    assert_equal 2, passing_report.checks.size
    assert_equal 3, with_ok_lint.checks.size
    assert_equal "0 issues across 5 files", with_ok_lint.checks.last.detail
    refute_includes with_ok_lint.to_s, "Static AOT lint passed"

    bad_lint = FakeLint.new(
      files_checked: 3,
      diagnostics: ["app/models/item.rb:4:1 [integer_overflow] overflow"],
      rendered: "Static AOT lint failed with 1 issue(s) across 3 files:\n  app/models/item.rb:4:1 [integer_overflow] overflow"
    )
    with_bad_lint = passing_report.with_lint(bad_lint)

    refute with_bad_lint.ok?
    assert_equal :fail, with_bad_lint.checks.last.status
    assert_equal "1 issue(s) across 3 files", with_bad_lint.checks.last.detail
    assert_includes with_bad_lint.to_s, "  [FAIL    ] static lint        1 issue(s) across 3 files\n\nStatic AOT lint failed"
  end

  test "which and check_writable_dir handle symlinks and relative paths" do
    Dir.mktmpdir do |dir|
      target_bin = File.join(dir, "real_tool")
      File.write(target_bin, "#!/bin/sh\n")
      File.chmod(0o755, target_bin)

      good_link = File.join(dir, "good_tool")
      broken_link = File.join(dir, "broken_tool")
      File.symlink(target_bin, good_link)
      File.symlink(File.join(dir, "does_not_exist"), broken_link)

      assert_equal good_link, Toolchain.which("good_tool", extra_paths: [dir])
      assert_nil Toolchain.which("broken_tool", extra_paths: [dir])
      assert_equal good_link, Toolchain.which(good_link)
      assert_nil Toolchain.which(broken_link)

      broken_cache = File.join(dir, "broken_cache")
      File.symlink(File.join(dir, "missing_target"), broken_cache)
      tc = Toolchain.new(path: File.join(dir, "toolchain.env"), values: {})
      broken_check = tc.send(:check_writable_dir, "CACHE", broken_cache)
      assert_equal :missing, broken_check.status

      Dir.chdir(dir) do
        rel_check = tc.send(:check_writable_dir, "CACHE", "nested/relative/cache")
        assert_equal :ok, rel_check.status
      end
    end
  end

  private

  def make_executable(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, path)
    path
  end

  def cache_check_for(cache_path)
    values = cache_path.nil? ? {} : { "CACHE" => cache_path }
    tc = Toolchain.new(path: "/opt/toolchain.env", values: values)
    tc.doctor(target: :native).checks.find { |c| c.name == "CACHE" }
  end

  def build_complete_toolchain_layout(dir)
    spinel_home = File.join(dir, "spinel")
    wasi_sdk = File.join(dir, "wasi-sdk")
    sqlite_src = File.join(dir, "sqlite")
    web_modules = File.join(dir, "web_node_modules")
    rails_gems = File.join(dir, "rails_gems")
    cache_dir = File.join(dir, "cache/nested/dir")
    bin_dir = File.join(dir, "path_bin")

    make_executable(File.join(spinel_home, "bin/spinel"))
    make_executable(File.join(spinel_home, "bin/spin"))
    FileUtils.mkdir_p(File.join(spinel_home, "lib/wasm32-wasi"))
    File.write(File.join(spinel_home, "lib/wasm32-wasi/libspinel_rt.a"), "rt")
    File.write(File.join(spinel_home, "lib/libspinel_rt.a"), "rt")
    File.write(File.join(spinel_home, "Makefile"), "all:\n")

    roundhouse = make_executable(File.join(dir, "roundhouse"))

    make_executable(File.join(wasi_sdk, "bin/clang"))
    make_executable(File.join(wasi_sdk, "bin/llvm-ar"))
    make_executable(File.join(wasi_sdk, "bin/llvm-strip"))

    FileUtils.mkdir_p([sqlite_src, web_modules, rails_gems, bin_dir])
    File.write(File.join(sqlite_src, "sqlite3.c"), "/* sqlite */\n")

    make_executable(File.join(bin_dir, "npx"))
    make_executable(File.join(bin_dir, "fake-cc"))
    make_executable(File.join(bin_dir, "ar"))

    {
      "SPINEL_HOME" => spinel_home,
      "ROUNDHOUSE_BIN" => roundhouse,
      "WASI_SDK" => wasi_sdk,
      "SQLITE_SRC" => sqlite_src,
      "WEB_NODE_MODULES" => web_modules,
      "RAILS_GEMS" => rails_gems,
      "CACHE" => cache_dir,
      "_BIN_DIR" => bin_dir
    }
  end

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
