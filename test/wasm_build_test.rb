require "test_helper"
require "instant_record/compiler"
require "digest"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"

class WasmBuildTest < ActiveSupport::TestCase
  GEM_ROOT = File.expand_path("..", __dir__)

  test "input_digest is deterministic, sensitive to config and inputs, and excludes out-of-root overrides" do
    Dir.mktmpdir do |dir|
      env = create_app_fixture(dir)
      outside_file = File.join(dir, "outside.rb")
      in_root_file = File.join(env[:app_root], "lib/extra_helper.rb")
      FileUtils.mkdir_p(File.dirname(in_root_file))
      File.write(outside_file, "OUTSIDE = 1\n")
      File.write(in_root_file, "EXTRA = 1\n")

      base = build_for(env)
      digest = base.input_digest
      assert_match(/\A[0-9a-f]{64}\z/, digest)
      assert_equal digest, build_for(env).input_digest

      variants = {
        models: build_for(env, models: %w[Task Note]).input_digest,
        sync_windows: build_for(env, sync_windows: { "Task" => { limit: 10 } }).input_digest,
        mount_path: build_for(env, mount_path: "/sync").input_digest,
        endpoint: build_for(env, endpoint: "http://127.0.0.1:4000/sync").input_digest,
        baseline: build_for(env, baseline: 20261120000001).input_digest,
        island: build_for(env, island: "inbox").input_digest,
        overrides: build_for(env, overrides: { include: { files: ["lib/extra_helper.rb"] } }).input_digest,
        shell_snapshot: build_for(env, shell_snapshot: "snap-v1").input_digest
      }
      variants.each do |name, variant_digest|
        refute_equal digest, variant_digest, "expected input_digest to change for #{name}"
      end

      assert_equal digest, build_for(env, endpoint: "/instant_record/", mount_path: "/instant_record/").input_digest

      pyc = File.join(env[:app_root], "app/models/cached.pyc")
      File.write(pyc, "bytecode")
      assert_equal digest, base.input_digest
      File.delete(pyc)

      with_in_root = build_for(env, overrides: { include: { files: ["lib/extra_helper.rb"] } })
      before_in_root = with_in_root.input_digest
      File.write(in_root_file, "EXTRA = 2\n")
      refute_equal before_in_root, with_in_root.input_digest

      with_outside = build_for(env, overrides: { include: { files: ["../outside.rb"] } })
      before_outside = with_outside.input_digest
      File.write(outside_file, "OUTSIDE = 2\n")
      assert_equal before_outside, with_outside.input_digest

      File.write(InstantRecord::Compiler::SchemaLock.path(env[:app_root]), "{\"version\":1}\n")
      with_lock = base.input_digest
      refute_equal digest, with_lock

      File.write(File.join(env[:app_root], "db/migrate/20261120000001_create_tasks.rb"), "# changed\n")
      refute_equal with_lock, base.input_digest

      demo_base = build_for(env, app_source: nil, models: ["Task"], baseline: 1)
      demo_same = build_for(env, app_source: nil, models: ["Other"], baseline: 999)
      demo_snap = build_for(env, app_source: nil, shell_snapshot: "demo-snap")
      assert_equal demo_base.input_digest, demo_same.input_digest
      refute_equal demo_base.input_digest, demo_snap.input_digest
    end
  end

  test "input_digest matches reference glob and pathname digest across dotfiles, symlinks, overlapping paths, and chunk boundaries" do
    Dir.mktmpdir do |dir|
      env = create_app_fixture(dir)
      app_root = env[:app_root]
      outside = File.join(dir, "outside")
      extra_mig = File.join(dir, "extra_migrations")
      FileUtils.mkdir_p(File.join(app_root, "app/models/.hidden/deep"))
      FileUtils.mkdir_p(File.join(app_root, "app/models/dir.pyc"))
      FileUtils.mkdir_p(File.join(app_root, "db/migrate/nested"))
      FileUtils.mkdir_p(File.join(app_root, "lib"))
      FileUtils.mkdir_p(File.join(outside, "sub"))
      FileUtils.mkdir_p(extra_mig)

      # Dotfiles, nested hidden dirs, .pyc files and .pyc directories
      File.write(File.join(app_root, "app/.root_dot"), "dot\n")
      File.write(File.join(app_root, "app/models/.hidden/.secret"), "secret\n")
      File.write(File.join(app_root, "app/models/.hidden/deep/nested.rb"), "class Nested; end\n")
      File.write(File.join(app_root, "app/models/ignored.pyc"), "bytecode")
      File.write(File.join(app_root, "app/models/dir.pyc/kept.rb"), "class Kept; end\n")
      File.write(File.join(app_root, "app/models/dir.pyc/ignored.pyc"), "bytecode2")

      # Boundary file sizes: 0 bytes, exact 64 KiB chunk, and multi-chunk binary
      File.binwrite(File.join(app_root, "app/models/empty.rb"), "")
      File.binwrite(File.join(app_root, "app/models/exact_chunk.bin"), ("A" * 65_536).b)
      File.binwrite(File.join(app_root, "app/models/multi_chunk.bin"), (0..255).map(&:chr).join.b * 400)

      # Symlinks: valid file, symlink to .pyc named .rb, symlink named .pyc, dir symlink, cyclic symlink, broken symlink
      target_rb = File.join(outside, "target.rb")
      target_pyc = File.join(outside, "target.pyc")
      symdir_file = File.join(outside, "sub/not_descended.rb")
      File.write(target_rb, "TARGET = 1\n")
      File.write(target_pyc, "TARGET_PYC")
      File.write(symdir_file, "IGNORED = 1\n")
      File.symlink(target_rb, File.join(app_root, "app/models/sym_file.rb"))
      File.symlink(target_pyc, File.join(app_root, "app/models/sym_to_pyc.rb"))
      File.symlink(target_rb, File.join(app_root, "app/models/sym_named.pyc"))
      File.symlink(File.join(outside, "sub"), File.join(app_root, "app/models/sym_dir"))
      File.symlink(File.join(app_root, "app"), File.join(app_root, "app/models/sym_loop"))
      File.symlink(File.join(outside, "missing.rb"), File.join(app_root, "app/models/broken_sym.rb"))

      # Overlapping, duplicate, relative-with-parent, missing, and symlinked migration dirs
      File.write(File.join(app_root, "db/migrate/nested/20261120000002_nested.rb"), "class NestedMig; end\n")
      File.write(File.join(extra_mig, "20261120000003_extra.rb"), "class ExtraMig; end\n")
      sym_mig = File.join(dir, "sym_migrations")
      File.symlink(extra_mig, sym_mig)

      # Config overrides (base + island + out-of-root)
      File.write(File.join(app_root, "lib/from_config.rb"), "CFG = 1\n")
      File.write(File.join(app_root, "lib/from_island.rb"), "ISL = 1\n")
      File.write(File.join(outside, "escape.rb"), "ESC = 1\n")
      File.write(File.join(app_root, "config/instant_record.yml"), <<~YAML)
        include:
          files:
            - lib/from_config.rb
            - ../outside/escape.rb
        islands:
          inbox:
            include:
              files:
                - lib/from_island.rb
      YAML

      build = build_for(
        env,
        island: "inbox",
        migration_paths: [
          File.join(app_root, "db/migrate"),
          File.join(app_root, "db/migrate"),
          File.join(app_root, "db"),
          File.join(app_root, "db/migrate/nested"),
          File.join(app_root, "db/migrate/../migrate"),
          File.join(app_root, "db/does_not_exist"),
          sym_mig,
          extra_mig
        ]
      )

      initial = build.input_digest
      assert_equal reference_input_digest(build), initial

      # Mutating symlinked regular file target changes digest and stays equal to reference
      File.write(target_rb, "TARGET = 2\n")
      after_sym_mutation = build.input_digest
      refute_equal initial, after_sym_mutation
      assert_equal reference_input_digest(build), after_sym_mutation

      # Mutating a file inside a symlinked directory does NOT change digest
      File.write(symdir_file, "IGNORED = 2\n")
      assert_equal after_sym_mutation, build.input_digest

      # Mutating a file inside a .pyc directory DOES change digest
      File.write(File.join(app_root, "app/models/dir.pyc/kept.rb"), "class Kept; VERSION = 2; end\n")
      after_pyc_dir_mutation = build.input_digest
      refute_equal after_sym_mutation, after_pyc_dir_mutation
      assert_equal reference_input_digest(build), after_pyc_dir_mutation

      # Sibling directory sharing gem_root string prefix computes exact relative path
      fake_gem = File.join(dir, "gem")
      sibling_app = File.join(dir, "gem_sibling")
      FileUtils.mkdir_p(File.join(fake_gem, "lib/instant_record"))
      FileUtils.mkdir_p(File.join(sibling_app, "app/models"))
      File.write(File.join(fake_gem, "lib/instant_record/a.rb"), "A = 1\n")
      File.write(File.join(sibling_app, "app/models/s.rb"), "S = 1\n")
      sibling_build = build_for(env, gem_root: fake_gem, app_source: sibling_app, migration_paths: [])
      assert_equal reference_input_digest(sibling_build), sibling_build.input_digest

      # gem_root == "/" matches Pathname#relative_path_from
      root_build = build_for(env, gem_root: "/", app_source: sibling_app, migration_paths: [])
      sample_paths = [File.join(sibling_app, "app/models/s.rb"), env[:toolchain]].sort
      actual_root_digest = Digest::SHA256.new
      expected_root_digest = Digest::SHA256.new
      root_build.send(:update_files_digest, actual_root_digest, sample_paths)
      sample_paths.each do |path|
        expected_root_digest.update(Pathname(path).relative_path_from(Pathname("/")).to_s)
        expected_root_digest.update(File.binread(path))
      end
      assert_equal expected_root_digest.hexdigest, actual_root_digest.hexdigest

      # Input under a shallower ancestor sorting before paths under a deeper ancestor of gem_root
      nested_gem = File.join(dir, "a/b/gem_root")
      nested_app = File.join(dir, "a/b/app_é")
      nested_ws = File.join(dir, "a/b/ws")
      shallow_tc = write_toolchain(dir, name: "0_toolchain.env")
      FileUtils.mkdir_p(File.join(nested_gem, "lib/instant_record"))
      FileUtils.mkdir_p(File.join(nested_app, "app/models"))
      FileUtils.mkdir_p(File.join(nested_ws, "web/src"))
      File.write(File.join(nested_gem, "lib/instant_record/g.rb"), "G = 1\n")
      File.write(File.join(nested_app, "app/models/n.rb"), "N = 1\n")
      File.write(File.join(nested_ws, "web/index.html"), "<html></html>\n")
      File.write(File.join(nested_ws, "web/src/m.js"), "console.log(1);\n")
      nested_build = build_for(
        env,
        gem_root: nested_gem,
        app_source: nested_app,
        workspace: nested_ws,
        toolchain: shallow_tc,
        migration_paths: []
      )
      assert_equal reference_input_digest(nested_build), nested_build.input_digest

      # Exact ancestor paths (including "/") after a cached shallower ancestor match Pathname#relative_path_from
      stubbed_build = build_for(env, gem_root: nested_gem, app_source: nested_app, workspace: nested_ws, toolchain: shallow_tc, migration_paths: [])
      stubbed_build.define_singleton_method(:update_file_content_digest) { |d, p, _| d.update("|#{p}\n") }
      ancestor_paths = ["/", File.join(dir, "0_a"), File.join(dir, "a"), File.join(dir, "a/b"), nested_gem, File.join(nested_app, "app/models/n.rb")].sort
      actual_anc = Digest::SHA256.new
      expected_anc = Digest::SHA256.new
      stubbed_build.send(:update_files_digest, actual_anc, ancestor_paths)
      ancestor_paths.each do |path|
        expected_anc.update(Pathname(path).relative_path_from(Pathname(nested_gem)).to_s)
        expected_anc.update("|#{path}\n")
      end
      assert_equal expected_anc.hexdigest, actual_anc.hexdigest
    end
  end

  test "outside_stylesheets extracts unique preconnects and non-crossorigin https stylesheet preloads" do
    Dir.mktmpdir do |dir|
      env = create_app_fixture(dir)
      build = build_for(env)

      assert_equal [], build.outside_stylesheets(env[:app_root])

      layouts = File.join(env[:app_root], "app/views/layouts")
      FileUtils.mkdir_p(layouts)
      File.write(File.join(layouts, "a_application.html.erb"), <<~HTML)
        <link rel="preconnect" href="https://fonts.googleapis.com">
        <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter">
        <link rel="stylesheet" href="https://cdn.example/app.css" crossorigin="anonymous">
        <link rel="stylesheet" href="/assets/local.css">
        <link rel="stylesheet" href="http://insecure.example/style.css">
      HTML
      File.write(File.join(layouts, "b_mail.html.erb"), <<~HTML)
        <link rel="preconnect" href="https://fonts.googleapis.com">
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
        <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Mono">
      HTML

      expected = [
        '    <link rel="preconnect" href="https://fonts.googleapis.com">',
        '    <link rel="preload" as="style" href="https://fonts.googleapis.com/css2?family=Inter">',
        '    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>',
        '    <link rel="preload" as="style" href="https://fonts.googleapis.com/css2?family=Mono">'
      ]
      assert_equal expected, build.outside_stylesheets(env[:app_root])
    end
  end

  test "warm_scripts hashes deferred css and js files and versions controllers and demo inbox" do
    Dir.mktmpdir do |dir|
      env = create_app_fixture(dir)
      assets = File.join(dir, "assets")
      controllers = File.join(assets, "controllers")
      FileUtils.mkdir_p(controllers)

      non_demo = build_for(env)
      assert_equal [], non_demo.warm_scripts(assets)

      File.write(File.join(assets, "extra.css"), "body { color: red; }\n")
      File.write(File.join(assets, "app.js"), "console.log('app');\n")
      File.write(File.join(assets, "inbox.js"), "console.log('inbox');\n")
      File.write(File.join(controllers, "mail_controller.js"), "export default class {}\n")

      ctrl_v = Digest::SHA256.file(File.join(controllers, "mail_controller.js")).hexdigest[0, 10]
      inbox_v = Digest::SHA256.file(File.join(assets, "inbox.js")).hexdigest[0, 10]

      non_demo_scripts = non_demo.warm_scripts(assets, deferred_css: %w[extra.css missing.css])
      assert_equal 1, non_demo_scripts.size
      expected_urls = [
        "/assets/extra.css",
        "/assets/app.js",
        "/assets/inbox.js",
        "/assets/controllers/mail_controller.js?v=#{ctrl_v}"
      ]
      assert_includes non_demo_scripts.first, JSON.generate(expected_urls)

      demo = build_for(env, app_source: nil)
      demo_scripts = demo.warm_scripts(assets, deferred_css: %w[extra.css])
      assert_includes demo_scripts.first, "/assets/inbox.js?v=#{inbox_v}"

      tag_before = non_demo_scripts.first[/instant_record\.warmed"\) !== "([0-9a-f]{12})"/, 1]
      assert tag_before
      File.write(File.join(assets, "app.js"), "console.log('app v2');\n")
      tag_after = non_demo.warm_scripts(assets, deferred_css: %w[extra.css]).first[/instant_record\.warmed"\) !== "([0-9a-f]{12})"/, 1]
      refute_equal tag_before, tag_after
    end
  end

  test "inject_preloads handles small and split css sets, worker scripts, external stylesheets, and empty no-ops" do
    Dir.mktmpdir do |dir|
      env = create_app_fixture(dir)
      build = build_for(env)

      empty_dist = File.join(dir, "empty_dist")
      FileUtils.mkdir_p(empty_dist)
      original_html = "<!doctype html><html><head>\n  </head><body></body></html>"
      File.write(File.join(empty_dist, "index.html"), original_html)
      build.inject_preloads(empty_dist, env[:app_root])
      assert_equal original_html, File.read(File.join(empty_dist, "index.html"))

      small_dist = File.join(dir, "small_dist")
      FileUtils.mkdir_p(File.join(small_dist, "assets"))
      FileUtils.mkdir_p(File.join(small_dist, "harness"))
      FileUtils.mkdir_p(File.join(env[:app_root], "app/views/layouts"))
      File.write(File.join(env[:app_root], "app/views/layouts/application.html.erb"),
        '<link rel="stylesheet" href="https://fonts.example/a.css">')
      File.write(File.join(small_dist, "index.html"), original_html)
      File.write(File.join(small_dist, "harness/worker-abc.js"), "// w\n")
      File.write(File.join(small_dist, "harness/main-abc.js"), "// m\n")
      %w[custom.css theme.css extra.css].each do |css|
        File.write(File.join(small_dist, "assets", css), "body{}\n")
      end

      build.inject_preloads(small_dist, env[:app_root])
      small_html = File.read(File.join(small_dist, "index.html"))
      assert_includes small_html, '<link rel="preload" as="style" href="https://fonts.example/a.css">'
      assert_includes small_html, 'window.__worker = new Worker("/harness/worker-abc.js", { type: "module" })'
      refute_includes small_html, "main-abc.js"
      %w[custom.css theme.css extra.css].each do |css|
        assert_includes small_html, %(<link rel="preload" as="style" fetchpriority="low" href="/assets/#{css}">)
      end
      refute_includes small_html, "instant_record.warmed"

      large_dist = File.join(dir, "large_dist")
      FileUtils.mkdir_p(File.join(large_dist, "assets"))
      File.write(File.join(large_dist, "index.html"), original_html)
      %w[base-deadbeef01.css ui.css mail.css admin.css extra.css].each do |css|
        File.write(File.join(large_dist, "assets", css), "body{}\n")
      end

      build.inject_preloads(large_dist, nil)
      large_html = File.read(File.join(large_dist, "index.html"))
      %w[base-deadbeef01.css ui.css mail.css].each do |css|
        assert_includes large_html, %(<link rel="preload" as="style" fetchpriority="low" href="/assets/#{css}">)
      end
      %w[admin.css extra.css].each do |css|
        refute_includes large_html, %(<link rel="preload" as="style" fetchpriority="low" href="/assets/#{css}">)
        assert_includes large_html, %("/assets/#{css}")
      end
    end
  end

  test "ensure_web_node_modules creates, repoints, preserves real dirs, and rejects missing or broken links" do
    Dir.mktmpdir do |dir|
      env = create_app_fixture(dir)
      web = File.join(dir, "web")
      FileUtils.mkdir_p(web)
      modules_link = File.join(web, "node_modules")

      first_nm = File.join(dir, "nm_one")
      second_nm = File.join(dir, "nm_two")
      missing_nm = File.join(dir, "nm_missing")
      FileUtils.mkdir_p(first_nm)
      FileUtils.mkdir_p(second_nm)

      unset_tc = write_toolchain(dir, name: "unset.env", web_node_modules: nil)
      err = assert_raises(InstantRecord::Compiler::BuildError) do
        build_for(env, toolchain: unset_tc).send(:ensure_web_node_modules, web)
      end
      assert_includes err.message, "WEB_NODE_MODULES is missing (unset)"

      first_tc = write_toolchain(dir, name: "first.env", web_node_modules: first_nm)
      build_for(env, toolchain: first_tc).send(:ensure_web_node_modules, web)
      assert File.symlink?(modules_link)
      assert_equal first_nm, File.readlink(modules_link)

      second_tc = write_toolchain(dir, name: "second.env", web_node_modules: second_nm)
      build_for(env, toolchain: second_tc).send(:ensure_web_node_modules, web)
      assert_equal second_nm, File.readlink(modules_link)

      missing_tc = write_toolchain(dir, name: "missing.env", web_node_modules: missing_nm)
      repoint_err = assert_raises(InstantRecord::Compiler::BuildError) do
        build_for(env, toolchain: missing_tc).send(:ensure_web_node_modules, web)
      end
      assert_includes repoint_err.message, "WEB_NODE_MODULES does not exist at #{missing_nm}"
      assert_equal second_nm, File.readlink(modules_link)

      FileUtils.rm_rf(second_nm)
      broken_err = assert_raises(InstantRecord::Compiler::BuildError) do
        build_for(env, toolchain: second_tc).send(:ensure_web_node_modules, web)
      end
      assert_includes broken_err.message, "WEB_NODE_MODULES symlink target does not exist (#{second_nm})"

      File.delete(modules_link)
      FileUtils.mkdir_p(modules_link)
      build_for(env, toolchain: unset_tc).send(:ensure_web_node_modules, web)
      assert File.directory?(modules_link)
      refute File.symlink?(modules_link)
    end
  end

  test "copy_hotwire_assets collects from RAILS_GEMS and falls back to loaded specs for missing files" do
    Dir.mktmpdir do |dir|
      env = create_app_fixture(dir)
      rails_gems = File.join(dir, "rails_gems")
      fallback_gem = File.join(dir, "fallback_stimulus")
      assets = File.join(dir, "out_assets")
      FileUtils.mkdir_p(File.join(rails_gems, "turbo-rails/app/assets/javascripts"))
      FileUtils.mkdir_p(File.join(rails_gems, "z-duplicate/assets"))
      FileUtils.mkdir_p(File.join(fallback_gem, "app/assets/javascripts"))
      FileUtils.mkdir_p(assets)

      File.write(File.join(rails_gems, "turbo-rails/app/assets/javascripts/turbo.min.js"), "// turbo from RAILS_GEMS\n")
      File.write(File.join(rails_gems, "z-duplicate/assets/turbo.min.js"), "// duplicate turbo\n")
      File.write(File.join(fallback_gem, "app/assets/javascripts/stimulus.min.js"), "// stimulus from spec\n")
      File.write(File.join(fallback_gem, "app/assets/javascripts/stimulus-loading.js"), "// loading from spec\n")

      tc = write_toolchain(dir, name: "gems.env", rails_gems: rails_gems)
      build = build_for(env, toolchain: tc)

      fake_spec = Struct.new(:full_gem_path).new(fallback_gem)
      original_turbo = Gem.loaded_specs["turbo-rails"]
      original_stimulus = Gem.loaded_specs["stimulus-rails"]
      begin
        Gem.loaded_specs.delete("turbo-rails")
        Gem.loaded_specs["stimulus-rails"] = fake_spec
        build.send(:copy_hotwire_assets, assets)
      ensure
        original_turbo ? (Gem.loaded_specs["turbo-rails"] = original_turbo) : Gem.loaded_specs.delete("turbo-rails")
        original_stimulus ? (Gem.loaded_specs["stimulus-rails"] = original_stimulus) : Gem.loaded_specs.delete("stimulus-rails")
      end

      assert_equal "// turbo from RAILS_GEMS\n", File.read(File.join(assets, "turbo.min.js"))
      assert_equal "// stimulus from spec\n", File.read(File.join(assets, "stimulus.min.js"))
      assert_equal "// loading from spec\n", File.read(File.join(assets, "stimulus-loading.js"))
    end
  end

  test "swap_dist replaces output cleanly and restores previous output on rename failure" do
    Dir.mktmpdir do |dir|
      env = create_app_fixture(dir)
      build = build_for(env)
      FileUtils.mkdir_p(build.build_dir)

      output = File.join(env[:workspace], "web/dist")
      FileUtils.mkdir_p(output)
      File.write(File.join(output, "index.html"), "old")

      dist = File.join(build.build_dir, "site")
      FileUtils.mkdir_p(dist)
      File.write(File.join(dist, "index.html"), "new")

      build.send(:swap_dist, dist, output)
      assert_equal "new", File.read(File.join(output, "index.html"))
      refute File.exist?(dist)
      refute File.exist?(File.join(build.build_dir, "previous-site"))

      missing_dist = File.join(build.build_dir, "does-not-exist")
      assert_raises(Errno::ENOENT) { build.send(:swap_dist, missing_dist, output) }
      assert_equal "new", File.read(File.join(output, "index.html"))
      refute File.exist?(File.join(build.build_dir, "previous-site"))
    end
  end

  test "version_controller_urls versions js controllers in importmap and application configs" do
    Dir.mktmpdir do |dir|
      env = create_app_fixture(dir)
      build = build_for(env)
      app = File.join(dir, "staged_app")
      emit = File.join(dir, "emit")
      FileUtils.mkdir_p(File.join(app, "app/javascript/controllers/nested"))
      FileUtils.mkdir_p(File.join(emit, "config"))

      ctrl_path = File.join(app, "app/javascript/controllers/inbox_controller.js")
      File.write(ctrl_path, "export default class InboxController {}\n")
      File.write(File.join(app, "app/javascript/controllers/README.md"), "ignore\n")
      version = Digest::SHA256.file(ctrl_path).hexdigest[0, 10]

      File.write(File.join(emit, "config/importmap.rb"), 'pin "inbox", to: "/assets/controllers/inbox_controller.js"')
      File.write(File.join(emit, "config/application.rb"), 'ASSETS = ["/assets/controllers/inbox_controller.js"]')

      build.send(:version_controller_urls, app, emit)

      assert_equal %(pin "inbox", to: "/assets/controllers/inbox_controller.js?v=#{version}"), File.read(File.join(emit, "config/importmap.rb"))
      assert_equal %(ASSETS = ["/assets/controllers/inbox_controller.js?v=#{version}"]), File.read(File.join(emit, "config/application.rb"))
    end
  end

  test "disable_jemalloc comments out allocator line in spin.toml and ignores missing file" do
    Dir.mktmpdir do |dir|
      env = create_app_fixture(dir)
      build = build_for(env)
      emit = File.join(dir, "emit")
      FileUtils.mkdir_p(emit)

      build.send(:disable_jemalloc, emit)

      toml = File.join(emit, "spin.toml")
      File.write(toml, "[package]\nname = \"app\"\nallocator = \"jemalloc\"\n")
      build.send(:disable_jemalloc, emit)
      assert_equal "[package]\nname = \"app\"\n# allocator = \"jemalloc\"  (wasm build: no jemalloc)\n", File.read(toml)
    end
  end

  test "clean removes paths inside build_dir and refuses paths outside build_dir" do
    Dir.mktmpdir do |dir|
      env = create_app_fixture(dir)
      build = build_for(env)
      inside = File.join(build.build_dir, "emit")
      FileUtils.mkdir_p(inside)
      File.write(File.join(inside, "a.rb"), "# ok\n")

      build.send(:clean, inside)
      refute File.exist?(inside)

      outside_paths = [
        build.build_dir,
        File.dirname(build.build_dir),
        "#{build.build_dir}-other",
        File.join(build.build_dir, "../escape")
      ]
      outside_paths.each do |bad|
        err = assert_raises(InstantRecord::Compiler::BuildError) { build.send(:clean, bad) }
        assert_includes err.message, "Refusing to clean outside #{build.build_dir}"
      end
    end
  end

  test "run short-circuits when stamp matches input_digest and web/dist/index.html exists" do
    Dir.mktmpdir do |dir|
      env = create_app_fixture(dir)
      out = StringIO.new
      build = build_for(env, out: out)

      InstantRecord::Compiler::SchemaLock.write!(
        root: env[:app_root],
        migration_paths: [File.join(env[:app_root], "db/migrate")]
      )
      output = File.join(env[:workspace], "web/dist")
      FileUtils.mkdir_p(output)
      FileUtils.mkdir_p(build.build_dir)
      File.write(File.join(output, "index.html"), "<html></html>")
      File.write(File.join(build.build_dir, "stamp"), build.input_digest)

      result = build.run
      assert_equal Pathname(output), result
      assert_equal "build is current\n", out.string
      refute File.exist?(File.join(build.build_dir, "app-src"))
    end
  end

  private

  def create_app_fixture(dir)
    app_root = File.join(dir, "app")
    workspace = File.join(dir, "workspace")
    FileUtils.mkdir_p(File.join(app_root, "app/models"))
    FileUtils.mkdir_p(File.join(app_root, "config"))
    FileUtils.mkdir_p(File.join(app_root, "db/migrate"))
    FileUtils.mkdir_p(File.join(workspace, "web/src"))

    File.write(File.join(app_root, "Gemfile"), "source 'https://rubygems.org'\n")
    File.write(File.join(app_root, "config/routes.rb"), "Rails.application.routes.draw { root 'tasks#index' }\n")
    File.write(File.join(app_root, "app/models/task.rb"), "class Task < ApplicationRecord\nend\n")
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
    File.write(File.join(workspace, "web/index.html"), "<!doctype html><html><head>\n  </head><body></body></html>")
    File.write(File.join(workspace, "web/src/main.js"), "console.log('boot');\n")

    toolchain = write_toolchain(dir)
    { app_root: app_root, workspace: workspace, toolchain: toolchain }
  end

  def write_toolchain(dir, name: "toolchain.env", web_node_modules: File.join(dir, "node_modules"), rails_gems: nil)
    path = File.join(dir, name)
    lines = [
      "SPINEL_HOME=#{dir}/spinel",
      "ROUNDHOUSE_BIN=#{dir}/roundhouse",
      "SQLITE_SRC=#{dir}/sqlite",
      "WASI_SDK=#{dir}/wasi-sdk",
      "CACHE=#{dir}/cache"
    ]
    lines << "WEB_NODE_MODULES=#{web_node_modules}" if web_node_modules
    lines << "RAILS_GEMS=#{rails_gems}" if rails_gems
    File.write(path, lines.join("\n") + "\n")
    path
  end

  def build_for(env, **overrides)
    options = {
      workspace: env[:workspace],
      gem_root: GEM_ROOT,
      toolchain: env[:toolchain],
      app_source: env[:app_root],
      models: ["Task"],
      endpoint: "/instant_record",
      migration_paths: [File.join(env[:app_root], "db/migrate")],
      out: StringIO.new
    }.merge(overrides)
    InstantRecord::Compiler::WasmBuild.new(**options)
  end

  def reference_input_digest(build)
    digest = Digest::SHA256.new
    build.send(:update_config_digest, digest)

    demo = build.instance_variable_get(:@demo)
    source_root = build.instance_variable_get(:@source_root)
    island = build.instance_variable_get(:@island)
    overrides = build.instance_variable_get(:@overrides)

    explicit = [
      build.toolchain.path,
      File.join(build.workspace, "web/index.html"),
      File.join(build.workspace, "web/vite.config.js"),
      File.join(build.workspace, "web/package.json"),
      File.join(build.workspace, "web/package-lock.json"),
      File.join(build.gem_root, "lib/instant_record.rb"),
      File.join(build.gem_root, "sig/instant_record/native.rbs"),
      File.join(build.gem_root, "sig/instant_record/native_host.rbs"),
      File.join(build.gem_root, "sig/instant_record/inertia.rbs")
    ]
    explicit << InstantRecord::Compiler::SchemaLock.path(source_root) unless demo
    (InstantRecord::Compiler::AppStage::FILES + [InstantRecord::Compiler::Manifest::CONFIG_FILE]).each do |name|
      explicit << File.join(source_root, name)
    end
    explicit.select! { |p| File.file?(p) }

    merged = InstantRecord::Compiler::Manifest.merge_overrides(
      InstantRecord::Compiler::Manifest.load_config(source_root, island: island),
      overrides
    )
    override_files = merged[:include]["files"].filter_map do |rel|
      candidate = File.expand_path(rel.delete_prefix("/"), source_root)
      candidate if candidate.start_with?("#{source_root}#{File::SEPARATOR}") && File.file?(candidate)
    end

    dir_files = build.send(:input_directories).flat_map do |dir|
      next [] unless File.directory?(dir)

      Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).filter_map do |rel|
        entry = File.join(dir, rel)
        entry if File.file?(entry) && !entry.end_with?(".pyc")
      end
    end

    gem_pathname = Pathname(build.gem_root)
    (explicit + override_files + dir_files).map { |p| File.expand_path(p) }.uniq.sort.each do |path|
      digest.update(Pathname(path).relative_path_from(gem_pathname).to_s)
      digest.update(File.binread(path))
    end

    digest.update(build.instance_variable_get(:@endpoint))
    digest.hexdigest
  end
end
