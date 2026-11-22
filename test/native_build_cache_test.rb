require "test_helper"
require "instant_record/compiler"
require "fileutils"
require "stringio"
require "tmpdir"

class NativeBuildCacheTest < ActiveSupport::TestCase
  GEM_ROOT = File.expand_path("..", __dir__)

  test "host native build caches sqlite3, native_shim, and rh_shim across rebuilds" do
    Dir.mktmpdir do |dir|
      env = create_stub_environment(dir)

      run_native_build(env)
      first_compiles = compiled_sources(env[:call_log])
      assert_includes first_compiles, "app.c"
      assert_includes first_compiles, "native_shim.c"
      assert_includes first_compiles, "rh_shim.c"
      assert_includes first_compiles, "sqlite3.c"

      cache_files = cached_entries(env[:cache_dir])
      assert_equal 1, cache_files.count { |f| f.start_with?("sqlite3-") && f.end_with?(".o") }
      assert_equal 1, cache_files.count { |f| f.start_with?("native_shim-") && f.end_with?(".o") }
      assert_equal 1, cache_files.count { |f| f.start_with?("rh_shim-") && f.end_with?(".o") }
      assert_empty temp_files(env[:cache_dir])

      reset_log(env[:call_log])
      out = run_native_build(env)
      second_compiles = compiled_sources(env[:call_log])
      assert_equal ["app.c"], second_compiles
      assert File.file?(out.join("libinstant_record_app.a"))
      assert File.file?(out.join("host"))
    end
  end

  test "iOS cross-build caches sqlite3, shims, libspinel_rt.a, and packages across rebuilds" do
    Dir.mktmpdir do |dir|
      env = create_stub_environment(dir)

      out1 = run_native_build(env, target: "iphonesimulator")
      first_compiles = compiled_sources(env[:call_log])
      assert_includes first_compiles, "app.c"
      assert_includes first_compiles, "native_shim.c"
      assert_includes first_compiles, "rh_shim.c"
      assert_includes first_compiles, "sqlite3.c"
      assert_includes first_compiles, "re.c"
      assert_includes first_compiles, "rt_core.c"
      assert_includes first_compiles, "sp_json.c"
      assert_includes first_compiles, "sp_stringio.c"
      assert_includes first_compiles, "sp_zlib.c"
      assert_equal 1, archive_calls_for(env[:call_log], "libspinel_rt").size
      assert File.file?(out1.join("libspinel_rt.a"))
      assert File.file?(out1.join("libinstant_record_app.a"))

      reset_log(env[:call_log])
      out2 = run_native_build(env, target: "iphonesimulator")
      assert_equal ["app.c"], compiled_sources(env[:call_log])
      assert_empty archive_calls_for(env[:call_log], "libspinel_rt")
      assert File.file?(out2.join("libspinel_rt.a"))
      assert File.file?(out2.join("libinstant_record_app.a"))
      assert_empty temp_files(env[:cache_dir])
    end
  end

  test "switching targets misses for a new target and re-hits an earlier target" do
    Dir.mktmpdir do |dir|
      env = create_stub_environment(dir)

      run_native_build(env, target: "iphonesimulator")
      reset_log(env[:call_log])

      # iphoneos must not reuse iphonesimulator objects or archive.
      run_native_build(env, target: "iphoneos")
      device_compiles = compiled_sources(env[:call_log])
      assert_includes device_compiles, "sqlite3.c"
      assert_includes device_compiles, "re.c"
      assert_includes device_compiles, "rt_core.c"
      assert_includes device_compiles, "sp_json.c"
      assert_equal 1, archive_calls_for(env[:call_log], "libspinel_rt").size

      # Switching back to iphonesimulator hits its cached objects and archive.
      reset_log(env[:call_log])
      run_native_build(env, target: "iphonesimulator")
      assert_equal ["app.c"], compiled_sources(env[:call_log])
      assert_empty archive_calls_for(env[:call_log], "libspinel_rt")
    end
  end

  test "source and header digest changes selectively invalidate only affected cache entries" do
    Dir.mktmpdir do |dir|
      env = create_stub_environment(dir)
      run_native_build(env, target: "iphonesimulator")

      # 1. Changing sqlite3.c invalidates only sqlite3.o.
      reset_log(env[:call_log])
      File.write(File.join(env[:sqlite_dir], "sqlite3.c"), "/* sqlite v2 */\n")
      run_native_build(env, target: "iphonesimulator")
      assert_equal %w[app.c sqlite3.c], compiled_sources(env[:call_log]).sort
      assert_empty archive_calls_for(env[:call_log], "libspinel_rt")

      # 2. Changing sqlite3.h invalidates sqlite3.o and rh_shim.o only.
      reset_log(env[:call_log])
      File.write(File.join(env[:sqlite_dir], "sqlite3.h"), "/* sqlite header v2 */\n")
      run_native_build(env, target: "iphonesimulator")
      assert_equal %w[app.c rh_shim.c sqlite3.c], compiled_sources(env[:call_log]).sort
      assert_empty archive_calls_for(env[:call_log], "libspinel_rt")

      # 3. Changing generated app.h invalidates only native_shim.o.
      reset_log(env[:call_log])
      File.write(env[:app_h_version_file], "app_h_v2")
      run_native_build(env, target: "iphonesimulator")
      assert_equal %w[app.c native_shim.c], compiled_sources(env[:call_log]).sort
      assert_empty archive_calls_for(env[:call_log], "libspinel_rt")

      # 4. Changing one RT_MEMBERS source recompiles only that object and re-archives libspinel_rt.a.
      reset_log(env[:call_log])
      File.write(File.join(env[:spinel_dir], "lib/rt_core.c"), "/* rt v2 */\n")
      run_native_build(env, target: "iphonesimulator")
      assert_equal %w[app.c rt_core.c], compiled_sources(env[:call_log]).sort
      assert_equal 1, archive_calls_for(env[:call_log], "libspinel_rt").size

      # 5. Changing one package source recompiles only that package (not libspinel_rt.a).
      reset_log(env[:call_log])
      File.write(File.join(env[:spinel_dir], "packages/json/sp_json.c"), "/* json v2 */\n")
      run_native_build(env, target: "iphonesimulator")
      assert_equal %w[app.c sp_json.c], compiled_sources(env[:call_log]).sort
      assert_empty archive_calls_for(env[:call_log], "libspinel_rt")

      # 6. Changing a Spinel lib header invalidates native_shim, RT_MEMBERS, packages, and libspinel_rt.a,
      #    while keeping sqlite3.o, rh_shim.o, and RE_SRC (which only includes lib/regexp) cached.
      reset_log(env[:call_log])
      File.write(File.join(env[:spinel_dir], "lib/spinel.h"), "/* spinel header v2 */\n")
      run_native_build(env, target: "iphonesimulator")
      assert_equal %w[app.c native_shim.c rt_core.c sp_json.c sp_stringio.c sp_zlib.c], compiled_sources(env[:call_log]).sort
      assert_equal 1, archive_calls_for(env[:call_log], "libspinel_rt").size

      # 7. Changing a vendored included .c file in a package invalidates only that package.
      reset_log(env[:call_log])
      File.write(File.join(env[:spinel_dir], "packages/zlib/miniz.c"), "/* miniz v2 */\n")
      run_native_build(env, target: "iphonesimulator")
      assert_equal %w[app.c sp_zlib.c], compiled_sources(env[:call_log]).sort
      assert_empty archive_calls_for(env[:call_log], "libspinel_rt")

      # 8. Changing a regexp header invalidates RE_SRC (and lib headers dependers), re-archiving libspinel_rt.a.
      reset_log(env[:call_log])
      File.write(File.join(env[:spinel_dir], "lib/regexp/re.h"), "/* re header v2 */\n")
      run_native_build(env, target: "iphonesimulator")
      assert_includes compiled_sources(env[:call_log]), "re.c"
      assert_equal 1, archive_calls_for(env[:call_log], "libspinel_rt").size
    end
  end

  test "compiler and SDK version changes invalidate cached objects and runtime archive" do
    Dir.mktmpdir do |dir|
      env = create_stub_environment(dir)

      # Host build: changing cc --version invalidates host cached objects.
      run_native_build(env)
      reset_log(env[:call_log])
      File.write(env[:cc_version_file], "clang 18.0.0")
      run_native_build(env)
      assert_equal %w[app.c native_shim.c rh_shim.c sqlite3.c], compiled_sources(env[:call_log]).sort

      # iOS build: changing SDK version invalidates all iOS cached objects and libspinel_rt.a.
      run_native_build(env, target: "iphonesimulator")
      reset_log(env[:call_log])
      File.write(env[:sdk_version_file], "26.3")
      run_native_build(env, target: "iphonesimulator")
      compiles = compiled_sources(env[:call_log]).sort
      assert_equal %w[app.c native_shim.c re.c rh_shim.c rt_core.c sp_json.c sp_stringio.c sp_zlib.c sqlite3.c], compiles
      assert_equal 1, archive_calls_for(env[:call_log], "libspinel_rt").size

      # iOS build: changing clang --version also invalidates all iOS cached objects and libspinel_rt.a.
      reset_log(env[:call_log])
      File.write(env[:cc_version_file], "clang 19.0.0")
      run_native_build(env, target: "iphonesimulator")
      compiles = compiled_sources(env[:call_log]).sort
      assert_equal %w[app.c native_shim.c re.c rh_shim.c rt_core.c sp_json.c sp_stringio.c sp_zlib.c sqlite3.c], compiles
      assert_equal 1, archive_calls_for(env[:call_log], "libspinel_rt").size
    end
  end

  test "cflags changes invalidate only the entries compiled with those flags" do
    Dir.mktmpdir do |dir|
      env = create_stub_environment(dir)
      run_native_build(env, target: "iphonesimulator")

      # Changing SQLITE_CFLAGS invalidates only sqlite3.o.
      reset_log(env[:call_log])
      sqlite_subclass = Class.new(InstantRecord::Compiler::NativeBuild) do
        const_set(:SQLITE_CFLAGS, (InstantRecord::Compiler::NativeBuild::SQLITE_CFLAGS + %w[-DSQLITE_EXTRA=1]).freeze)
      end
      run_native_build(env, target: "iphonesimulator", builder_class: sqlite_subclass)
      assert_equal %w[app.c sqlite3.c], compiled_sources(env[:call_log]).sort
      assert_empty archive_calls_for(env[:call_log], "libspinel_rt")

      # Changing CFLAGS invalidates native_shim.o and rh_shim.o (not sqlite3.o or runtime).
      reset_log(env[:call_log])
      cflags_subclass = Class.new(InstantRecord::Compiler::NativeBuild) do
        const_set(:CFLAGS, (InstantRecord::Compiler::NativeBuild::CFLAGS + %w[-DEXTRA_SHIM=1]).freeze)
      end
      run_native_build(env, target: "iphonesimulator", builder_class: cflags_subclass)
      assert_equal %w[app.c native_shim.c rh_shim.c], compiled_sources(env[:call_log]).sort
      assert_empty archive_calls_for(env[:call_log], "libspinel_rt")

      # Changing RUNTIME_CFLAGS invalidates runtime objects, libspinel_rt.a, and packages (not sqlite3.o or shims).
      reset_log(env[:call_log])
      runtime_subclass = Class.new(InstantRecord::Compiler::NativeBuild) do
        const_set(:RUNTIME_CFLAGS, (InstantRecord::Compiler::NativeBuild::RUNTIME_CFLAGS + %w[-DEXTRA_RT=1]).freeze)
      end
      run_native_build(env, target: "iphonesimulator", builder_class: runtime_subclass)
      assert_equal %w[app.c re.c rt_core.c sp_json.c sp_stringio.c sp_zlib.c], compiled_sources(env[:call_log]).sort
      assert_equal 1, archive_calls_for(env[:call_log], "libspinel_rt").size
    end
  end

  test "different app workspaces sharing the same CACHE reuse cached native objects" do
    Dir.mktmpdir do |dir|
      env = create_stub_environment(dir)
      second_app = File.join(dir, "second_app")
      create_consumer_app(second_app)

      run_native_build(env, target: "iphonesimulator")
      reset_log(env[:call_log])

      out = run_native_build(env, target: "iphonesimulator", app_root: second_app)
      assert_equal ["app.c"], compiled_sources(env[:call_log])
      assert_empty archive_calls_for(env[:call_log], "libspinel_rt")
      assert File.file?(out.join("libinstant_record_app.a"))
      assert File.file?(out.join("libspinel_rt.a"))
    end
  end

  test "failed compilation leaves no partial cache entry or temp file, and concurrent builds do not corrupt cache" do
    Dir.mktmpdir do |dir|
      env = create_stub_environment(dir)

      # Simulate a compiler crash after writing partial bytes to -o for sqlite3.c.
      File.write(env[:fail_source_file], "sqlite3.c")
      assert_raises(InstantRecord::Compiler::BuildError) do
        run_native_build(env)
      end
      assert_empty cached_entries(env[:cache_dir]).select { |f| f.start_with?("sqlite3-") }
      assert_empty temp_files(env[:cache_dir])

      # Fixing the failure compiles and caches cleanly.
      File.delete(env[:fail_source_file])
      run_native_build(env)
      sqlite_cached = cached_entries(env[:cache_dir]).find { |f| f.start_with?("sqlite3-") }
      assert sqlite_cached

      # A zero-byte entry at a cache path is treated as a miss and atomically replaced.
      File.write(File.join(env[:cache_dir], "native-objects", sqlite_cached), "")
      reset_log(env[:call_log])
      run_native_build(env)
      assert_equal %w[app.c sqlite3.c], compiled_sources(env[:call_log]).sort
      assert_operator File.size(File.join(env[:cache_dir], "native-objects", sqlite_cached)), :>, 0

      # Concurrent writers racing on the same cache key atomically publish intact bytes.
      builder = InstantRecord::Compiler::NativeBuild.new(
        workspace: File.join(dir, "concurrent_ws"),
        gem_root: GEM_ROOT,
        toolchain: env[:toolchain_file],
        app_source: env[:app_root],
        models: ["Task"],
        endpoint: "/instant_record",
        out: StringIO.new
      )
      target_file = File.join(env[:cache_dir], "native-objects", "race-entry.o")
      expected_payload = ("VALID-OBJECT-PAYLOAD-" * 2048).b

      threads = 8.times.map do
        Thread.new do
          builder.send(:fetch_cached_file, target_file) do |tmp_path|
            File.open(tmp_path, "wb") do |io|
              io.write(expected_payload[0, expected_payload.bytesize / 2])
              sleep 0.01
              io.write(expected_payload[(expected_payload.bytesize / 2)..])
            end
          end
          File.binread(target_file)
        end
      end

      results = threads.map(&:value)
      assert results.all? { |bytes| bytes == expected_payload }
      assert_empty temp_files(env[:cache_dir])
    end
  end

  private

  def run_native_build(env, target: nil, app_root: env[:app_root], builder_class: InstantRecord::Compiler::NativeBuild)
    workspace = File.join(app_root, "tmp/instant_record/compiled")
    with_path(env[:bin_dir]) do
      builder_class.new(
        workspace: workspace,
        gem_root: GEM_ROOT,
        toolchain: env[:toolchain_file],
        app_source: app_root,
        models: ["Task"],
        endpoint: "/instant_record",
        target: target,
        baseline: 20261120000001,
        migration_paths: [File.join(app_root, "db/migrate")],
        out: StringIO.new
      ).run
    end
  end

  def with_path(prepend_dir)
    old_path = ENV["PATH"]
    old_cc = ENV["CC"]
    ENV["PATH"] = "#{prepend_dir}#{File::PATH_SEPARATOR}#{old_path}"
    ENV["CC"] = File.join(prepend_dir, "cc")
    yield
  ensure
    ENV["PATH"] = old_path
    ENV["CC"] = old_cc
  end

  def reset_log(call_log)
    File.write(call_log, "")
  end

  def compiled_sources(call_log)
    File.readlines(call_log, chomp: true).filter_map do |line|
      next unless line.match?(/\A(cc|xcrun)\b/) && line.include?(" -c ")

      source = line[/ -c (\S+)/, 1]
      File.basename(source) if source
    end
  end

  def archive_calls_for(call_log, name_fragment)
    File.readlines(call_log, chomp: true).select do |line|
      line.start_with?("ar ") && line.include?(name_fragment)
    end
  end

  def cached_entries(cache_dir)
    native_dir = File.join(cache_dir, "native-objects")
    return [] unless File.directory?(native_dir)

    Dir.children(native_dir).reject { |name| name.start_with?(".") }.sort
  end

  def temp_files(cache_dir)
    native_dir = File.join(cache_dir, "native-objects")
    return [] unless File.directory?(native_dir)

    Dir.children(native_dir).select { |name| name.start_with?(".") }.sort
  end

  def create_consumer_app(app_root)
    FileUtils.mkdir_p(File.join(app_root, "app/models"))
    FileUtils.mkdir_p(File.join(app_root, "app/controllers"))
    FileUtils.mkdir_p(File.join(app_root, "app/screens"))
    FileUtils.mkdir_p(File.join(app_root, "config"))
    FileUtils.mkdir_p(File.join(app_root, "db/migrate"))

    File.write(File.join(app_root, "Gemfile"), "source 'https://rubygems.org'\n")
    File.write(File.join(app_root, "config/routes.rb"), "Rails.application.routes.draw { root 'tasks#index' }\n")
    File.write(File.join(app_root, "app/models/task.rb"), "class Task < ApplicationRecord\n  include InstantRecord::Syncable\nend\n")
    File.write(File.join(app_root, "app/screens/tasks_screen.rb"), "class TasksScreen < InstantRecord::Native::Screen\n  def body; navigation(title: 'Tasks') {}; end\nend\n")
    File.write(File.join(app_root, "db/schema.rb"), "ActiveRecord::Schema[8.1].define(version: 2026_11_20_000001) do\nend\n")
    File.write(File.join(app_root, "db/migrate/20261120000001_create_tasks.rb"), <<~RUBY)
      class CreateTasks < ActiveRecord::Migration[8.1]
        def change
          create_table :tasks, id: :string do |t|
            t.string :title
          end
        end
      end
    RUBY
  end

  def create_stub_environment(dir)
    tools = File.join(dir, "tools")
    spinel = File.join(tools, "spinel")
    sqlite = File.join(tools, "sqlite")
    cache = File.join(tools, "cache")
    bin_dir = File.join(tools, "bin")
    call_log = File.join(tools, "calls.log")
    cc_version_file = File.join(tools, "cc_version.txt")
    sdk_version_file = File.join(tools, "sdk_version.txt")
    app_h_version_file = File.join(tools, "app_h_version.txt")
    fail_source_file = File.join(tools, "fail_source.txt")
    app_root = File.join(dir, "my_app")

    create_consumer_app(app_root)

    [
      File.join(spinel, "bin"),
      File.join(spinel, "lib/regexp/shim"),
      File.join(spinel, "packages/json"),
      File.join(spinel, "packages/stringio"),
      File.join(spinel, "packages/zlib"),
      sqlite,
      cache,
      bin_dir
    ].each { |path| FileUtils.mkdir_p(path) }

    File.write(call_log, "")
    File.write(cc_version_file, "clang 17.0.0")
    File.write(sdk_version_file, "26.2")
    File.write(app_h_version_file, "app_h_v1")

    File.write(File.join(spinel, "lib/libspinel_rt.a"), "rt")
    File.write(File.join(spinel, "lib/spinel.h"), "/* spinel header v1 */\n")
    File.write(File.join(spinel, "lib/regexp/re.h"), "/* re header v1 */\n")
    File.write(File.join(spinel, "lib/regexp/re.c"), "/* re v1 */\n")
    File.write(File.join(spinel, "lib/rt_core.c"), "/* rt v1 */\n")
    File.write(File.join(spinel, "Makefile"), "RE_SRC = lib/regexp/re.c\nRT_MEMBERS = rt_core\n")
    %w[json stringio zlib].each do |pkg|
      File.write(File.join(spinel, "packages/#{pkg}/sp_#{pkg}.o"), "o")
      File.write(File.join(spinel, "packages/#{pkg}/sp_#{pkg}.c"), "/* #{pkg} v1 */\n")
    end
    File.write(File.join(sqlite, "sqlite3.c"), "/* sqlite v1 */\n")
    File.write(File.join(sqlite, "sqlite3.h"), "/* sqlite header v1 */\n")

    roundhouse = File.join(tools, "roundhouse")
    write_exec(roundhouse, <<~SH)
      #!/bin/sh
      echo "roundhouse $*" >> "#{call_log}"
      out=""
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "-o" ]; then out="$2"; shift 2; else shift; fi
      done
      mkdir -p "$out/runtime/active_record" "$out/config" "$out/app/models/instant_record/client" "$out/app/views"
      printf 'require_relative "runtime/db"\\n' > "$out/boot.rb"
      printf 'require_relative "boot"\\nif ARGV.length > 0 && ARGV[0] == "sidekiq"\\nend\\n' > "$out/main.rb"
      printf 'allocator = "jemalloc"\\n' > "$out/spin.toml"
      printf 'module Schema; end\\n' > "$out/config/schema.rb"
      printf 'require "openssl"\\n  def self.aes_256_gcm_encrypt; end\\nend\\n' > "$out/runtime/message_digest.rb"
      printf 'sqlite3_bind_int64\\n' > "$out/runtime/db.rb"
      printf '    def has_changes_to_save?\\n    end\\n' > "$out/runtime/active_record/base.rb"
      printf 'module InstantRecord; module Host; end; end\\n' > "$out/app/models/instant_record/host.rb"
    SH

    write_exec(File.join(spinel, "bin/spin"), <<~SH)
      #!/bin/sh
      echo "spin $*" >> "#{call_log}"
      echo "-I."
    SH

    write_exec(File.join(spinel, "bin/spinel"), <<~SH)
      #!/bin/sh
      echo "spinel $*" >> "#{call_log}"
      out=""
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "-o" ]; then out="$2"; shift 2; else shift; fi
      done
      printf 'int app_boot(void) { return 0; }\\n' > "$out"
      ver=$(cat "#{app_h_version_file}")
      printf '/* %s */\\nint app_boot(void);\\n' "$ver" > "$(dirname "$out")/app.h"
    SH

    write_exec(File.join(bin_dir, "cc"), <<~SH)
      #!/bin/sh
      echo "cc $*" >> "#{call_log}"
      if [ "$1" = "--version" ]; then
        cat "#{cc_version_file}"
        exit 0
      fi
      src=""
      out=""
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "-c" ]; then src="$2"; shift 2
        elif [ "$1" = "-o" ]; then out="$2"; shift 2
        else shift
        fi
      done
      if [ -f "#{fail_source_file}" ] && [ -n "$src" ]; then
        fail_base=$(cat "#{fail_source_file}")
        if [ "$(basename "$src")" = "$fail_base" ]; then
          mkdir -p "$(dirname "$out")"
          printf 'PARTIAL' > "$out"
          echo "synthetic compiler failure for $fail_base" >&2
          exit 1
        fi
      fi
      if [ -n "$out" ]; then
        mkdir -p "$(dirname "$out")"
        printf 'obj:%s' "$(basename "$src")" > "$out"
      fi
    SH

    write_exec(File.join(bin_dir, "xcrun"), <<~SH)
      #!/bin/sh
      echo "xcrun $*" >> "#{call_log}"
      sdk="$2"
      if [ "$3" = "--show-sdk-path" ]; then
        echo "/FakeSDK/$sdk"
        exit 0
      fi
      if [ "$3" = "--show-sdk-version" ]; then
        cat "#{sdk_version_file}"
        exit 0
      fi
      if [ "$3" = "--show-sdk-build-version" ]; then
        echo "23C53"
        exit 0
      fi
      if [ "$3" = "clang" ] && [ "$4" = "--version" ]; then
        cat "#{cc_version_file}"
        exit 0
      fi
      src=""
      out=""
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "-c" ]; then src="$2"; shift 2
        elif [ "$1" = "-o" ]; then out="$2"; shift 2
        else shift
        fi
      done
      if [ -n "$out" ]; then
        mkdir -p "$(dirname "$out")"
        printf 'ios-obj:%s:%s' "$sdk" "$(basename "$src")" > "$out"
      fi
    SH

    write_exec(File.join(bin_dir, "ar"), <<~SH)
      #!/bin/sh
      echo "ar $*" >> "#{call_log}"
      mkdir -p "$(dirname "$2")"
      printf '!<arch>\\n%s\\n' "$*" > "$2"
    SH

    toolchain_file = File.join(tools, "toolchain.env")
    File.write(toolchain_file, <<~ENV)
      TOOLS=#{tools}
      SPINEL_HOME=$TOOLS/spinel
      ROUNDHOUSE_BIN=$TOOLS/roundhouse
      SQLITE_SRC=$TOOLS/sqlite
      CACHE=$TOOLS/cache
    ENV

    {
      toolchain_file: toolchain_file,
      bin_dir: bin_dir,
      call_log: call_log,
      cache_dir: cache,
      sqlite_dir: sqlite,
      spinel_dir: spinel,
      cc_version_file: cc_version_file,
      sdk_version_file: sdk_version_file,
      app_h_version_file: app_h_version_file,
      fail_source_file: fail_source_file,
      app_root: app_root
    }
  end

  def write_exec(path, content)
    File.write(path, content)
    File.chmod(0o755, path)
  end
end
