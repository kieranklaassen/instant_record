require "test_helper"
require "instant_record/compiler"
require "fileutils"
require "stringio"
require "tmpdir"

class NativeBuildTest < ActiveSupport::TestCase
  GEM_ROOT = File.expand_path("..", __dir__)

  test "validates target and normalizes blank options" do
    Dir.mktmpdir do |dir|
      toolchain = write_minimal_toolchain(dir)

      err = assert_raises(ArgumentError) do
        InstantRecord::Compiler::NativeBuild.new(
          workspace: dir,
          gem_root: GEM_ROOT,
          toolchain: toolchain,
          target: "android"
        )
      end
      assert_equal "Unknown target android. Leave it out for this machine, or use iphonesimulator or iphoneos.", err.message

      app_root = File.join(dir, "app")
      FileUtils.mkdir_p(File.join(app_root, "app/screens"))
      File.write(File.join(app_root, "app/screens/tasks_screen.rb"), <<~RUBY)
        class TasksScreen < InstantRecord::Native::Screen
          contract "TasksCard" do |c|
            c.string :title
          end
        end
      RUBY

      blank_target = InstantRecord::Compiler::NativeBuild.new(
        workspace: dir,
        gem_root: GEM_ROOT,
        toolchain: toolchain,
        app_source: app_root,
        target: "",
        endpoint: "",
        mount_path: "",
        out: StringIO.new
      )
      blank_target.generate_contracts
      assert File.file?(File.join(dir, ".build-native/generated/InstantRecordContracts.swift"))
      assert_nil blank_target.instance_variable_get(:@endpoint)
      assert_nil blank_target.instance_variable_get(:@mount_path)
    end
  end

  test "generate_contracts writes Swift and Kotlin files, mirrors extra outputs, and skips empty apps" do
    Dir.mktmpdir do |dir|
      toolchain = write_minimal_toolchain(dir)
      app_root = File.join(dir, "app")
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(File.join(app_root, "app/screens"))

      File.write(File.join(app_root, "app/screens/plain_screen.rb"), "class PlainScreen < InstantRecord::Native::Screen; end\n")
      empty_out = StringIO.new
      empty_builder = InstantRecord::Compiler::NativeBuild.new(
        workspace: workspace,
        gem_root: GEM_ROOT,
        toolchain: toolchain,
        app_source: app_root,
        out: empty_out
      )
      assert_equal [], empty_builder.generate_contracts
      refute File.exist?(File.join(workspace, ".build-native/generated"))
      assert_equal "", empty_out.string

      File.write(File.join(app_root, "app/screens/tasks_screen.rb"), <<~RUBY)
        class TasksScreen < InstantRecord::Native::Screen
          contract "TasksCard" do |c|
            c.string :title
          end
        end
      RUBY

      swift_mirror = File.join(dir, "mirrors/swift/TasksContracts.swift")
      swift_out = StringIO.new
      swift_builder = InstantRecord::Compiler::NativeBuild.new(
        workspace: workspace,
        gem_root: GEM_ROOT,
        toolchain: toolchain,
        app_source: app_root,
        swift_out: swift_mirror,
        out: swift_out
      )
      contracts = swift_builder.generate_contracts
      assert_equal ["TasksCard"], contracts.map(&:component)

      generated_swift = File.join(workspace, ".build-native/generated/InstantRecordContracts.swift")
      generated_kotlin = File.join(workspace, ".build-native/generated/InstantRecordContracts.kt")
      assert File.file?(generated_swift)
      assert File.file?(swift_mirror)
      assert_equal File.read(generated_swift), File.read(swift_mirror)
      refute File.exist?(generated_kotlin)
      assert_equal "wrote #{generated_swift} (1 contracts)\n", swift_out.string

      kotlin_mirror = File.join(dir, "mirrors/kotlin/TasksContracts.kt")
      both_out = StringIO.new
      both_builder = InstantRecord::Compiler::NativeBuild.new(
        workspace: workspace,
        gem_root: GEM_ROOT,
        toolchain: toolchain,
        app_source: app_root,
        swift_out: generated_swift,
        kotlin_out: kotlin_mirror,
        kotlin_package: "com.example.tasks",
        out: both_out
      )
      both_builder.generate_contracts

      assert File.file?(generated_kotlin)
      assert File.file?(kotlin_mirror)
      assert_equal File.read(generated_kotlin), File.read(kotlin_mirror)
      assert_includes File.read(kotlin_mirror), "package com.example.tasks"
      assert_equal(
        "wrote #{generated_swift} (1 contracts)\nwrote #{generated_kotlin} (1 contracts)\n",
        both_out.string
      )
    end
  end

  test "makefile_list splits Spinel Makefile variables and raises BuildError when missing" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Makefile"), "RE_SRC = lib/regexp/a.c lib/regexp/b.c\nRT_MEMBERS = core gc\n")

      assert_equal %w[lib/regexp/a.c lib/regexp/b.c], InstantRecord::Compiler::NativeBuild.makefile_list(dir, "RE_SRC")
      assert_equal %w[core gc], InstantRecord::Compiler::NativeBuild.makefile_list(dir, "RT_MEMBERS")

      err = assert_raises(InstantRecord::Compiler::BuildError) do
        InstantRecord::Compiler::NativeBuild.makefile_list(dir, "MISSING_VAR")
      end
      assert_equal "Spinel's Makefile has no MISSING_VAR", err.message
    end
  end

  test "host build links host and shared library with platform-specific flags and logs outputs" do
    Dir.mktmpdir do |dir|
      env = create_stub_environment(dir)

      darwin_class = Class.new(InstantRecord::Compiler::NativeBuild) do
        def self.darwin?
          true
        end
      end
      darwin_out = StringIO.new
      darwin_dir = run_build(env, builder_class: darwin_class, out: darwin_out)

      library = darwin_dir.join("libinstant_record_app.a").to_s
      dylib = darwin_dir.join("libinstant_record_app.dylib").to_s
      host = darwin_dir.join("host").to_s
      runtime_lib = File.join(env[:spinel_dir], "lib/libspinel_rt.a")

      assert File.file?(library)
      assert File.file?(dylib)
      assert File.file?(host)
      assert_includes darwin_out.string, "wrote main_native.rb with screens: tasks\n"
      assert_includes darwin_out.string, "built #{library}, #{dylib} and #{host} (#{File.size(host)} bytes)\n"

      calls = File.readlines(env[:call_log], chomp: true)
      host_link = calls.find { |line| line.include?("native/host.c") && line.include?("-o #{host}") }
      assert host_link, "expected host link call in #{calls.inspect}"
      assert_includes host_link, "#{library} #{runtime_lib} -lm -o #{host}"

      shared_link = calls.find { |line| line.include?("-o #{dylib}") }
      assert shared_link, "expected dylib link call in #{calls.inspect}"
      assert_includes shared_link, "-dynamiclib -O2 -Wl,-force_load,#{library} #{runtime_lib} -lm -o #{dylib}"

      File.write(env[:call_log], "")
      linux_class = Class.new(InstantRecord::Compiler::NativeBuild) do
        def self.darwin?
          false
        end
      end
      linux_out = StringIO.new
      linux_dir = run_build(env, builder_class: linux_class, out: linux_out)

      so = linux_dir.join("libinstant_record_app.so").to_s
      assert File.file?(so)
      assert_includes linux_out.string, "built #{library}, #{so} and #{host} (#{File.size(host)} bytes)\n"

      linux_calls = File.readlines(env[:call_log], chomp: true)
      so_link = linux_calls.find { |line| line.include?("-o #{so}") }
      assert so_link, "expected shared .so link call in #{linux_calls.inspect}"
      assert_includes so_link, "-shared -O2 -Wl,--whole-archive #{library} -Wl,--no-whole-archive #{runtime_lib} -lm -o #{so}"
    end
  end

  test "cross-target build uses iphoneos triple without fPIC and generated C guards fail before cc" do
    Dir.mktmpdir do |dir|
      env = create_stub_environment(dir)

      ios_out = StringIO.new
      ios_dir = run_build(env, target: "iphoneos", out: ios_out)
      library = ios_dir.join("libinstant_record_app.a").to_s
      runtime = ios_dir.join("libspinel_rt.a").to_s

      assert File.file?(library)
      assert File.file?(runtime)
      refute File.exist?(ios_dir.join("host"))
      assert_includes ios_out.string, "built #{library} and #{runtime} for iphoneos\n"

      calls = File.readlines(env[:call_log], chomp: true)
      app_compile = calls.find { |line| line.start_with?("xcrun ") && line.include?(" -c ") && line.include?("app.c") }
      assert app_compile
      assert_includes app_compile, "-target arm64-apple-ios#{InstantRecord::Compiler::NativeBuild::IOS_MINIMUM}"
      refute_includes app_compile, "-fPIC"

      File.write(env[:call_log], "")
      File.write(env[:generated_c_file], <<~C)
        struct sp_InstantRecord__Native__Node_s {
          sp_StrStrHash * iv_link_params;
          sp_StrPolyHash * iv_args;
          sp_StrStrHash * iv_props;
        };
      C
      loose_err = assert_raises(InstantRecord::Compiler::BuildError) { run_build(env) }
      assert_includes loose_err.message, "the compiler typed a node's args loosely"
      assert_empty File.readlines(env[:call_log], chomp: true).select { |line| line.match?(/\A(cc|xcrun)\b/) && line.include?(" -c ") }

      File.write(env[:call_log], "")
      File.write(env[:generated_c_file], <<~C)
        #line 19 "app-src/app/screens/tasks_screen.rb"
          sp_raise_cls("TypeError", "wrong argument type (expected Hash)");
      C
      type_err = assert_raises(InstantRecord::Compiler::BuildError) { run_build(env) }
      assert_includes type_err.message, "app/screens/tasks_screen.rb:19"
      assert_empty File.readlines(env[:call_log], chomp: true).select { |line| line.match?(/\A(cc|xcrun)\b/) && line.include?(" -c ") }
    end
  end

  private

  def write_minimal_toolchain(dir)
    path = File.join(dir, "toolchain.env")
    File.write(path, <<~ENV)
      SPINEL_HOME=#{dir}/spinel
      SQLITE_SRC=#{dir}/sqlite
      CACHE=#{dir}/cache
    ENV
    path
  end

  def run_build(env, target: nil, builder_class: InstantRecord::Compiler::NativeBuild, out: StringIO.new)
    workspace = File.join(env[:app_root], "tmp/instant_record/compiled")
    old_path = ENV["PATH"]
    old_cc = ENV["CC"]
    ENV["PATH"] = "#{env[:bin_dir]}#{File::PATH_SEPARATOR}#{old_path}"
    ENV["CC"] = File.join(env[:bin_dir], "cc")
    builder_class.new(
      workspace: workspace,
      gem_root: GEM_ROOT,
      toolchain: env[:toolchain_file],
      app_source: env[:app_root],
      models: ["Task"],
      endpoint: "/instant_record",
      target: target,
      baseline: 20261120000001,
      migration_paths: [File.join(env[:app_root], "db/migrate")],
      out: out
    ).run
  ensure
    ENV["PATH"] = old_path
    ENV["CC"] = old_cc
  end

  def create_stub_environment(dir)
    tools = File.join(dir, "tools")
    spinel = File.join(tools, "spinel")
    sqlite = File.join(tools, "sqlite")
    cache = File.join(tools, "cache")
    bin_dir = File.join(tools, "bin")
    call_log = File.join(tools, "calls.log")
    generated_c_file = File.join(tools, "generated_app.c")
    app_root = File.join(dir, "my_app")

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
    File.write(generated_c_file, "int app_boot(void) { return 0; }\n")
    File.write(File.join(spinel, "lib/libspinel_rt.a"), "rt")
    File.write(File.join(spinel, "lib/spinel.h"), "/* spinel */\n")
    File.write(File.join(spinel, "lib/regexp/re.c"), "/* re */\n")
    File.write(File.join(spinel, "lib/rt_core.c"), "/* rt */\n")
    File.write(File.join(spinel, "Makefile"), "RE_SRC = lib/regexp/re.c\nRT_MEMBERS = rt_core\n")
    %w[json stringio zlib].each do |pkg|
      File.write(File.join(spinel, "packages/#{pkg}/sp_#{pkg}.o"), "o")
      File.write(File.join(spinel, "packages/#{pkg}/sp_#{pkg}.c"), "/* #{pkg} */\n")
    end
    File.write(File.join(sqlite, "sqlite3.c"), "/* sqlite */\n")
    File.write(File.join(sqlite, "sqlite3.h"), "/* sqlite */\n")

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
      printf '    def quote_string(str)\\n    end\\n' > "$out/runtime/active_record/connection.rb"
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
      cp "#{generated_c_file}" "$out"
      printf 'int app_boot(void);\\n' > "$(dirname "$out")/app.h"
    SH

    write_exec(File.join(bin_dir, "cc"), <<~SH)
      #!/bin/sh
      echo "cc $*" >> "#{call_log}"
      if [ "$1" = "--version" ]; then
        echo "clang 17.0.0"
        exit 0
      fi
      out=""
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "-o" ]; then out="$2"; shift 2; else shift; fi
      done
      if [ -n "$out" ]; then
        mkdir -p "$(dirname "$out")"
        printf 'native-out' > "$out"
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
        echo "26.2"
        exit 0
      fi
      if [ "$3" = "--show-sdk-build-version" ]; then
        echo "23C53"
        exit 0
      fi
      if [ "$3" = "clang" ] && [ "$4" = "--version" ]; then
        echo "clang 17.0.0"
        exit 0
      fi
      out=""
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "-o" ]; then out="$2"; shift 2; else shift; fi
      done
      if [ -n "$out" ]; then
        mkdir -p "$(dirname "$out")"
        printf 'ios-out' > "$out"
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
      spinel_dir: spinel,
      generated_c_file: generated_c_file,
      app_root: app_root
    }
  end

  def write_exec(path, content)
    File.write(path, content)
    File.chmod(0o755, path)
  end
end
