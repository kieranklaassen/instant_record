require "test_helper"
require "json"
require "open3"
require "tmpdir"

class GemspecTest < ActiveSupport::TestCase
  ROOT = File.expand_path("..", __dir__)
  GEMSPEC_PATH = File.join(ROOT, "instant_record.gemspec")

  test "gemspec version matches InstantRecord::VERSION and frontend/package.json" do
    spec = Gem::Specification.load(GEMSPEC_PATH)
    frontend_pkg = JSON.parse(File.read(File.join(ROOT, "frontend/package.json")))

    assert_equal InstantRecord::VERSION, spec.version.to_s
    assert_equal InstantRecord::VERSION, frontend_pkg.fetch("version")
  end

  test "gemspec packages required runtime, compiler, generator, frontend, and native files without demo or test artifacts" do
    spec = Gem::Specification.load(GEMSPEC_PATH)

    %w[
      lib/instant_record.rb
      lib/instant_record/compiler.rb
      lib/instant_record/compiler/wasm_build.rb
      lib/instant_record/compiler/native_build.rb
      lib/generators/instant_record/install/install_generator.rb
      lib/generators/instant_record/install/templates/instant_record.rb
      lib/generators/instant_record/ios/ios_generator.rb
      db/migrate/20260721000002_create_instant_record_outbox.rb
      db/migrate/20261119000201_add_scope_to_instant_record_changes.rb
      compiled/web/src/worker.js
      compiled/web/src/main.js
      compiled/web/src/server-request.js
      compiled/toolchain.env.example
      frontend/index.js
      frontend/files.js
      frontend/package.json
      sig/instant_record/native.rbs
      native/ios/InstantRecordNative/Package.swift
    ].each do |expected|
      assert_includes spec.files, expected, "expected #{expected} to be packaged in the gem"
    end

    refute spec.files.any? { |f| f.start_with?("compiled/pipeline/demo/") }, "demo overlays must not be packaged"
    refute spec.files.any? { |f| f.start_with?("frontend/test/") }, "frontend test helpers must not be packaged"
    refute spec.files.any? { |f| f.end_with?(".test.js") }, "JS test files must not be packaged"
  end

  test "gem build succeeds with zero RubyGems warnings" do
    Dir.mktmpdir do |dir|
      out_gem = File.join(dir, "instant_record-#{InstantRecord::VERSION}.gem")
      output, status = Open3.capture2e("gem", "build", GEMSPEC_PATH, "--output", out_gem, chdir: ROOT)

      assert status.success?, "gem build failed:\n#{output}"
      assert File.file?(out_gem), "expected built gem at #{out_gem}"
      refute_match(/WARNING:/, output, "expected zero RubyGems warnings:\n#{output}")
    end
  end
end
