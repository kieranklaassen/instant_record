require "digest"
require "fileutils"
require "json"
require "pathname"
require_relative "app_stage"
require_relative "browser_migrations"
require_relative "entry_builder"
require_relative "gem_vendor"
require_relative "runner"
require_relative "source_pages"
require_relative "toolchain"
require_relative "wasm_tree"

module InstantRecord
  class Compiler
    # Build the compiled browser app: Rails source -> seams -> Roundhouse -> Spinel -> wasm -> web/dist.
    class WasmBuild
      SPINEL_FLAGS = [].freeze
      WASM_OPT_LEVEL = "-Oz"
      WASM_OPT_PASS = "-Oz"
      STRIP = true
      SHELL_FORMAT = 1
      DEFAULT_SYNC_ENDPOINT = "http://127.0.0.1:3210/instant_record"

      REACTOR_EXPORTS = [
        "WasmBridge.handle_request",
        "WasmBridge.handle_sync",
        "WasmBridge.sync_plan",
        "WasmBridge.handle_stream",
        "WasmBridge.cursor",
        "WasmBridge.history"
      ].join(",").freeze

      SQLITE_CFLAGS = %w[
        -Oz -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_OMIT_SHARED_CACHE -DSQLITE_OMIT_WAL
        -DSQLITE_MAX_MMAP_SIZE=0 -DSQLITE_DEFAULT_SYNCHRONOUS=0 -DSQLITE_OMIT_DEPRECATED
        -DSQLITE_OMIT_PROGRESS_CALLBACK -DSQLITE_TEMP_STORE=2
        -DSQLITE_OMIT_UTF16 -DSQLITE_OMIT_AUTHORIZATION -DSQLITE_OMIT_COMPLETE
        -DSQLITE_OMIT_TRACE -DSQLITE_OMIT_TCL_VARIABLE -DSQLITE_OMIT_COMPILEOPTION_DIAGS
        -DSQLITE_OMIT_AUTOVACUUM -DSQLITE_OMIT_BLOB_LITERAL
      ].freeze

      WASI_CFLAGS = %w[
        --target=wasm32-wasip1
        -ffunction-sections
        -fdata-sections
        -D_WASI_EMULATED_MMAN
        -D_WASI_EMULATED_SIGNAL
        -D_WASI_EMULATED_PROCESS_CLOCKS
        -D_WASI_EMULATED_GETPID
      ].freeze

      WASM_OPT_FEATURES = %w[
        --enable-exception-handling
        --enable-bulk-memory
        --enable-nontrapping-float-to-int
        --enable-sign-ext
        --enable-mutable-globals
        --enable-reference-types
      ].freeze

      DEMO_MIGRATION_PLAN = {
        "version" => 1,
        "baseline" => 0,
        "migrations" => {},
        "history" => { "1" => "add-mail-tables" }
      }.freeze

      attr_reader :workspace, :gem_root, :pipeline_dir, :build_dir, :toolchain, :runner

      def initialize(
        workspace:,
        gem_root:,
        toolchain:,
        app_source: nil,
        models: [],
        endpoint: nil,
        baseline: nil,
        migration_paths: nil,
        shell_snapshot: nil,
        build_dir: nil,
        out: $stdout
      )
        @workspace = File.expand_path(workspace.to_s)
        @gem_root = File.expand_path(gem_root.to_s)
        @pipeline_dir = File.join(@gem_root, "compiled/pipeline")
        @build_dir = File.expand_path((build_dir || File.join(@workspace, ".build")).to_s)
        @toolchain = toolchain.is_a?(Toolchain) ? toolchain : Toolchain.load(toolchain)
        @app_source = app_source ? File.expand_path(app_source.to_s) : nil
        @demo = @app_source.nil?
        @models = models
        @endpoint = (endpoint || ENV.fetch("SYNC_ENDPOINT", DEFAULT_SYNC_ENDPOINT)).to_s.sub(%r{/+\z}, "")
        @baseline = baseline
        @migration_paths = migration_paths
        @shell_snapshot = shell_snapshot.nil? ? ENV.fetch("INSTANT_RECORD_SHELL_SNAPSHOT", "") : shell_snapshot.to_s
        @runner = Runner.new(build_dir: @build_dir)
        @out = out
      end

      def run
        FileUtils.mkdir_p(@build_dir)
        FileUtils.mkdir_p(@toolchain.fetch("CACHE"))

        stamp = File.join(@build_dir, "stamp")
        wanted = input_digest
        output = File.join(@workspace, "web/dist")
        if File.file?(stamp) && File.read(stamp) == wanted && File.file?(File.join(output, "index.html"))
          @out.puts "build is current"
          return Pathname(output)
        end
        File.delete(stamp) if File.exist?(stamp)

        path_env = {
          "PATH" => [@toolchain.join("SPINEL_HOME", "bin"), ENV.fetch("PATH", "")].join(File::PATH_SEPARATOR),
          "WASI_SDK" => @toolchain.fetch("WASI_SDK")
        }

        emitted = emit_tree(native: false)
        sqlite = sqlite_library
        flags = @runner.run(["spin", "flags"], cwd: emitted[:tree], env: path_env).split
        wasm = compile_reactor(emitted[:tree], flags, sqlite, path_env)
        final = optimize_wasm(emitted[:tree], wasm)

        dist, digest = build_web_site(emitted, final, wanted)
        swap_dist(dist, output)

        @out.puts "built web/dist with app-#{digest}.wasm (#{File.size(final)} bytes)"
        File.write(stamp, wanted)
        Pathname(output)
      end

      # Steps 1 to 3, shared with NativeBuild: staged app, Roundhouse emit, and
      # single-threaded tree with its Wasm reactor entry.
      def emit_tree(native: false)
        FileUtils.mkdir_p(@build_dir)
        app = File.join(@build_dir, "app-src")

        if @demo
          plan = DEMO_MIGRATION_PLAN
          DemoCarver.carve(
            gem_src: @gem_root,
            target: app,
            overlay_dir: File.join(@pipeline_dir, "demo"),
            native: native
          )
        else
          plan = BrowserMigrations.plan(
            root: @app_source,
            baseline: @baseline,
            migration_paths: @migration_paths
          )
          File.write(File.join(@build_dir, "browser-migrations.json"), JSON.generate(plan))
          AppStage.stage(source: @app_source, target: app, native: native)
        end

        GemVendor.vendor(gem_src: @gem_root, app_dir: app, demo: @demo)

        emit = File.join(@build_dir, "emit")
        clean(emit)
        @runner.run([@toolchain.fetch("ROUNDHOUSE_BIN"), "--target", "spinel", "-o", emit, app], log: "emit.log")

        version_controller_urls(app, emit)
        disable_jemalloc(emit)

        tree = File.join(@build_dir, "wasm-tree")
        clean(tree)
        EntryBuilder.write_wasm_entry(
          emit_dir: emit,
          demo: @demo,
          models: @models,
          migration_plan: plan,
          pipeline_dir: @pipeline_dir
        )
        WasmTree.build(source: emit, target: tree, demo: @demo)

        { app: app, emit: emit, tree: tree, plan: plan }
      end

      def input_digest
        digest = Digest::SHA256.new
        paths = [
          @toolchain.path,
          File.join(@workspace, "web/index.html"),
          File.join(@workspace, "web/vite.config.js"),
          File.join(@workspace, "web/package.json"),
          File.join(@workspace, "web/package-lock.json"),
          File.join(@gem_root, "lib/instant_record.rb")
        ].select { |p| File.file?(p) }

        inputs = [
          [@pipeline_dir, ["."]],
          [@workspace, ["web/src"]],
          [@gem_root, ["lib/instant_record", "app/models/instant_record"]]
        ]

        source_root = @app_source || File.join(@gem_root, "demo")
        inputs << [source_root, ["app", "config/routes", "config/locales"]]

        unless @demo
          inputs << [source_root, ["db/browser_migrate"]]
          Array(@migration_paths || [File.join(source_root, "db/migrate")]).each do |dir|
            inputs << [dir, ["."]]
          end
          digest.update(@baseline.to_s)
        end

        %w[config/routes.rb config/application.rb config/importmap.rb db/schema.rb Gemfile].each do |name|
          candidate = File.join(source_root, name)
          paths << candidate if File.file?(candidate)
        end

        digest.update(@demo ? "" : JSON.generate(@models))
        digest.update(@shell_snapshot)

        inputs.each do |base_root, folders|
          folders.each do |folder|
            full = folder == "." ? base_root : File.join(base_root, folder)
            next unless File.directory?(full)

            Dir.glob(File.join(full, "**/*")).each do |entry|
              paths << entry if File.file?(entry) && !entry.end_with?(".pyc")
            end
          end
        end

        gem_pathname = Pathname(@gem_root)
        paths.map { |p| File.expand_path(p) }.uniq.sort.each do |path|
          rel = Pathname(path).relative_path_from(gem_pathname).to_s
          digest.update(rel)
          digest.update(File.binread(path))
        end
        digest.update(@endpoint)
        digest.hexdigest
      end

      def outside_stylesheets(app_root)
        layouts = File.join(app_root, "app/views/layouts")
        return [] unless File.directory?(layouts)

        links = []
        Dir.children(layouts).sort.each do |name|
          full = File.join(layouts, name)
          next unless File.file?(full)

          File.read(full).scan(/<link\b[^>]*>/).each do |tag|
            href = tag[/href="(https:\/\/[^"<]+)"/, 1]
            next unless href

            if tag.include?('rel="preconnect"') && !links.include?("    #{tag}")
              links << "    #{tag}"
            end
            if tag.include?('rel="stylesheet"') && !tag.include?("crossorigin")
              links << %(    <link rel="preload" as="style" href="#{href}">)
            end
          end
        end
        links
      end

      def warm_scripts(assets_dir)
        urls = []
        seen = Digest::SHA256.new
        [
          [assets_dir, "/assets/"],
          [File.join(assets_dir, "controllers"), "/assets/controllers/"]
        ].each do |folder, prefix|
          next unless File.directory?(folder)

          Dir.children(folder).sort.each do |name|
            path = File.join(folder, name)
            next unless name.end_with?(".js") && File.file?(path)

            digest = Digest::SHA256.file(path).hexdigest[0, 10]
            seen.update(name + digest)
            versioned = prefix.end_with?("controllers/") || (name == "inbox.js" && @demo)
            urls << prefix + name + (versioned ? "?v=#{digest}" : "")
          end
        end
        return [] if urls.empty?

        tag = seen.hexdigest[0, 12]
        [
          %(    <script>try { if (localStorage.getItem("instant_record.warmed") !== "#{tag}") {) +
            %( localStorage.setItem("instant_record.warmed", "#{tag}");) +
            %( for (const url of #{JSON.generate(urls)}) fetch(url, { priority: "low" }).catch(function () {}); } } catch (error) {}</script>)
        ]
      end

      def inject_preloads(dist, app_root)
        links = app_root ? outside_stylesheets(app_root) : []
        harness_dir = File.join(dist, "harness")
        if File.directory?(harness_dir)
          Dir.children(harness_dir).sort.each do |name|
            if name.start_with?("worker-") && name.end_with?(".js")
              links << %(    <link rel="modulepreload" href="/harness/#{name}">)
            end
          end
        end

        assets_dir = File.join(dist, "assets")
        if File.directory?(assets_dir)
          Dir.children(assets_dir).sort.each do |name|
            links << %(    <link rel="preload" as="style" href="/assets/#{name}">) if name.end_with?(".css")
          end
        end

        links.concat(warm_scripts(assets_dir))
        return if links.empty?

        index_path = File.join(dist, "index.html")
        html = File.read(index_path)
        File.write(index_path, html.sub("  </head>") { "#{links.join("\n")}\n  </head>" })
      end

      private

      def clean(path)
        expanded = File.expand_path(path)
        raise BuildError, "Refusing to clean outside #{@build_dir}: #{expanded}" unless expanded.start_with?("#{@build_dir}#{File::SEPARATOR}")

        FileUtils.rm_rf(expanded)
      end

      def version_controller_urls(app, emit)
        controller_dir = File.join(app, "app/javascript/controllers")
        return unless File.directory?(controller_dir)

        versions = {}
        Dir.children(controller_dir).sort.each do |name|
          file = File.join(controller_dir, name)
          next unless name.end_with?(".js") && File.file?(file)

          versions[name] = Digest::SHA256.file(file).hexdigest[0, 10]
        end

        %w[config/importmap.rb config/application.rb].each do |config|
          path = File.join(emit, config)
          next unless File.file?(path)

          source = File.read(path)
          versions.each do |name, version|
            asset = "/assets/controllers/#{name}"
            source = source.gsub(asset, "#{asset}?v=#{version}")
          end
          File.write(path, source)
        end
      end

      def disable_jemalloc(emit)
        toml = File.join(emit, "spin.toml")
        return unless File.file?(toml)

        config = File.read(toml)
        File.write(toml, config.gsub("\nallocator = \"jemalloc\"", "\n# allocator = \"jemalloc\"  (wasm build: no jemalloc)"))
      end

      def sqlite_library
        shim = File.join(@pipeline_dir, "sqlite/rh_shim.c")
        key = Digest::SHA256.hexdigest(SQLITE_CFLAGS.join(" ") + File.read(shim))[0, 16]
        out = File.join(@toolchain.fetch("CACHE"), "sqlite-#{key}")
        archive = File.join(out, "libsqlite3.a")

        unless File.exist?(archive)
          FileUtils.mkdir_p(out)
          clang = @toolchain.join("WASI_SDK", "bin/clang")
          sqlite_src = @toolchain.fetch("SQLITE_SRC")
          @runner.run([clang, *WASI_CFLAGS, *SQLITE_CFLAGS, "-c", File.join(sqlite_src, "sqlite3.c"), "-o", File.join(out, "sqlite3.o")])
          @runner.run([clang, *WASI_CFLAGS, WASM_OPT_LEVEL, "-I#{sqlite_src}", "-c", shim, "-o", File.join(out, "rh_shim.o")])
          @runner.run([@toolchain.join("WASI_SDK", "bin/llvm-ar"), "rcs", archive, File.join(out, "sqlite3.o"), File.join(out, "rh_shim.o")])
        end

        out
      end

      def compile_reactor(tree, flags, sqlite, path_env)
        build_subdir = File.join(tree, "build")
        FileUtils.mkdir_p(build_subdir)
        app_c = File.join(build_subdir, "app.c")
        wasm = File.join(build_subdir, "app.wasm")
        shim_c = File.join(@pipeline_dir, "reactor_shim.c")
        sqlite_src = @toolchain.fetch("SQLITE_SRC")

        @runner.run(
          [
            "spinel", "--target=wasm32-wasi", "-c",
            "--ext-init", "app_boot",
            "--ext-entry", REACTOR_EXPORTS,
            *flags, *SPINEL_FLAGS,
            "main_wasm.rb", "-o", app_c
          ],
          cwd: tree,
          env: path_env.merge("CPATH" => sqlite_src),
          log: "spinel.log"
        )

        spinel_home = @toolchain.fetch("SPINEL_HOME")
        clang = @toolchain.join("WASI_SDK", "bin/clang")
        pkg_objs = %w[json stringio zlib].map { |pkg| File.join(spinel_home, "packages", pkg, "sp_#{pkg}_wasi.o") }

        @runner.run(
          [
            clang, *WASI_CFLAGS, "-mexec-model=reactor", WASM_OPT_LEVEL,
            "-Wno-all", "-ffunction-sections", "-fdata-sections", "-ffp-contract=off",
            "-DSP_INT_OVERFLOW_MODE_RAISE",
            "-I#{File.join(spinel_home, 'lib')}",
            "-I#{File.join(spinel_home, 'lib/regexp')}",
            "-I#{File.join(spinel_home, 'lib/wasi')}",
            "-I#{sqlite_src}",
            "-I#{build_subdir}",
            "-mllvm", "-wasm-enable-sjlj",
            "-mllvm", "-wasm-use-legacy-eh=false",
            app_c, shim_c,
            *pkg_objs,
            File.join(spinel_home, "lib/wasm32-wasi/libspinel_rt.a"),
            "-L#{sqlite}", "-lsqlite3",
            "-lm", "-lsetjmp",
            "-lwasi-emulated-signal", "-lwasi-emulated-process-clocks",
            "-lwasi-emulated-getpid", "-lwasi-emulated-mman",
            "-Wl,-z,stack-size=8388608", "-Wl,--gc-sections",
            "-o", wasm
          ],
          cwd: tree,
          env: path_env,
          log: "clang.log"
        )
        wasm
      end

      def optimize_wasm(tree, wasm)
        final = wasm
        if STRIP
          stripped = File.join(tree, "build/app.stripped.wasm")
          @runner.run([@toolchain.join("WASI_SDK", "bin/llvm-strip"), "-o", stripped, final])
          final = stripped
        end
        wasm_opt = Toolchain.which("wasm-opt")
        if wasm_opt && WASM_OPT_PASS && !WASM_OPT_PASS.empty?
          opted = File.join(tree, "build/app.opt.wasm")
          @runner.run([wasm_opt, WASM_OPT_PASS, *WASM_OPT_FEATURES, final, "-o", opted], cwd: tree, log: "wasm-opt.log")
          final = opted
        end
        final
      end

      def build_web_site(emitted, final_wasm, wanted)
        app = emitted[:app]
        emit = emitted[:emit]
        plan = emitted[:plan]

        web = File.join(@workspace, "web")
        modules = File.join(web, "node_modules")
        unless File.exist?(modules) || File.symlink?(modules)
          web_node_modules = @toolchain.fetch("WEB_NODE_MODULES")
          File.symlink(web_node_modules, modules)
        end

        digest = Digest::SHA256.file(final_wasm).hexdigest[0, 10]
        dist = File.join(@build_dir, "site")

        main_wasm_source = File.read(File.join(emit, "main_wasm.rb"))
        model_set = main_wasm_source[/model_set = "([^"]*)"/, 1]
        raise BuildError, "Missing model_set in #{File.join(emit, 'main_wasm.rb')}" unless model_set

        schema_source = File.read(File.join(app, "db/schema.rb"))
        shell_fingerprint = Digest::SHA256.hexdigest([SHELL_FORMAT.to_s, model_set, schema_source].join("\n"))
        schema_digest = Digest::SHA256.file(File.join(emit, "config/schema.rb")).hexdigest

        @runner.run(
          ["npx", "vite", "build", "--outDir", dist, "--emptyOutDir"],
          cwd: web,
          env: {
            "VITE_WASM_URL" => "/app-#{digest}.wasm",
            "VITE_SHELL_FINGERPRINT" => shell_fingerprint,
            "VITE_SHELL_SNAPSHOT" => @shell_snapshot,
            "VITE_SHARED_INBOX_DEMO" => @demo ? "1" : "",
            "VITE_SYNC_ENDPOINT" => @endpoint,
            "VITE_SOURCE_VERSION" => wanted[0, 12],
            "VITE_SCHEMA_VERSION" => plan["version"].to_s,
            "VITE_SCHEMA_BASELINE" => plan["baseline"].nil? ? "" : plan["baseline"].to_s,
            "VITE_MIGRATION_HISTORY" => JSON.generate(plan["history"] || {}),
            "VITE_SCHEMA_DIGEST" => schema_digest
          },
          log: "vite.log"
        )

        File.write(File.join(dist, "instant-record-release.json"), JSON.generate("version" => wanted))
        FileUtils.cp(final_wasm, File.join(dist, "app-#{digest}.wasm"))

        assets = File.join(dist, "assets")
        FileUtils.mkdir_p(File.join(assets, "controllers"))
        [
          File.join(app, "app/assets/stylesheets"),
          File.join(app, "app/assets/images"),
          File.join(app, "app/assets/builds"),
          File.join(emit, "static/assets"),
          File.join(app, "app/javascript")
        ].each do |asset_dir|
          FileCopy.copy_tree(asset_dir, assets) if File.directory?(asset_dir)
        end

        copy_hotwire_assets(assets)

        if @demo
          SourcePages.write(
            app_dir: app,
            dist_dir: dist,
            version: wanted[0, 12],
            demo_dir: File.join(@gem_root, "demo"),
            pipeline_dir: @pipeline_dir
          )
        end

        source_root = @app_source || File.join(@gem_root, "demo")
        shell_worker = File.join(source_root, "app/views/pwa/service-worker.js")
        FileUtils.cp(shell_worker, File.join(dist, "service-worker.js")) if File.file?(shell_worker)

        inject_preloads(dist, source_root)
        [dist, digest]
      end

      def copy_hotwire_assets(assets)
        rails_gems = @toolchain["RAILS_GEMS"]
        %w[turbo.min.js stimulus.min.js stimulus-loading.js].each do |name|
          found = find_hotwire_asset(name, rails_gems)
          FileUtils.cp(found, assets) if found
        end
      end

      def find_hotwire_asset(name, rails_gems)
        if rails_gems && File.directory?(rails_gems)
          match = Dir.glob(File.join(rails_gems, "**", name)).sort.first
          return match if match
        end

        %w[turbo-rails stimulus-rails].each do |gem_name|
          spec = Gem.loaded_specs[gem_name]
          next unless spec

          match = Dir.glob(File.join(spec.full_gem_path, "**", name)).sort.first
          return match if match
        end
        nil
      end

      def swap_dist(dist, output)
        previous = File.join(@build_dir, "previous-site")
        clean(previous)
        File.rename(output, previous) if File.directory?(output)
        begin
          File.rename(dist, output)
        rescue SystemCallError
          File.rename(previous, output) if File.directory?(previous) && !File.exist?(output)
          raise
        end
        clean(previous)
      end
    end
  end
end
