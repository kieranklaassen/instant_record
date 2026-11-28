require "digest"
require "fileutils"
require "json"
require "pathname"
require_relative "app_stage"
require_relative "browser_migrations"
require_relative "entry_builder"
require_relative "gem_vendor"
require_relative "manifest"
require_relative "runner"
require_relative "schema_lock"
require_relative "source_pages"
require_relative "static_linter"
require_relative "toolchain"
require_relative "wasm_tree"
require_relative "../shell"
require_relative "../trace/schema_extractor"

module InstantRecord
  class Compiler
    # Build the compiled browser app: Rails source -> seams -> Roundhouse -> Spinel -> wasm -> web/dist.
    class WasmBuild
      WASM_OPT_LEVEL = "-Oz"
      WASM_OPT_PASS = "-Oz"
      # A Ruby rescue is a setjmp, and every call inside a function that holds one is
      # wrapped. Inlining callees into it multiplies the wrapped calls: without this
      # flag the generated code is nearly twice the size.
      REACTOR_SIZE_CFLAGS = %w[-fno-inline].freeze
      SHELL_FORMAT = InstantRecord::Shell::FORMAT
      DEFAULT_SYNC_ENDPOINT = "http://127.0.0.1:3210/instant_record"
      SPINEL_PACKAGES = %w[json stringio zlib].freeze
      HOTWIRE_ASSETS = %w[turbo.min.js stimulus.min.js stimulus-loading.js].freeze
      CORE_PRELOAD_STYLES = %w[base ui mail].freeze

      REACTOR_EXPORTS = [
        "WasmBridge.handle_request",
        "WasmBridge.handle_sync",
        "WasmBridge.sync_plan",
        "WasmBridge.handle_stream",
        "WasmBridge.cursor",
        "WasmBridge.history",
        "WasmBridge.export_outbox",
        "WasmBridge.import_outbox",
        "WasmBridge.notices",
        "WasmBridge.branch_outbox",
        "WasmBridge.branch_replay"
      ].join(",").freeze

      PRECOMPRESS_JS = <<~'JS'
        const fs = require("fs"), path = require("path"), zlib = require("zlib");
        const params = { [zlib.constants.BROTLI_PARAM_QUALITY]: 11, [zlib.constants.BROTLI_PARAM_LGWIN]: 24 };
        for (const name of fs.readdirSync(process.argv[1], { recursive: true })) {
          const file = path.join(process.argv[1], String(name));
          if (!/\.(wasm|js|css|html|json|svg)$/.test(file) || !fs.statSync(file).isFile()) continue;
          const body = fs.readFileSync(file);
          if (body.length < 1024) continue;
          const size = { [zlib.constants.BROTLI_PARAM_SIZE_HINT]: body.length };
          fs.writeFileSync(file + ".br", zlib.brotliCompressSync(body, { params: { ...params, ...size } }));
          fs.writeFileSync(file + ".gz", zlib.gzipSync(body, { level: 9 }));
        }
      JS

      SQLITE_CFLAGS = %w[
        -Oz -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_OMIT_SHARED_CACHE -DSQLITE_OMIT_WAL
        -DSQLITE_MAX_MMAP_SIZE=0 -DSQLITE_DEFAULT_SYNCHRONOUS=0 -DSQLITE_OMIT_DEPRECATED
        -DSQLITE_OMIT_PROGRESS_CALLBACK -DSQLITE_TEMP_STORE=2
        -DSQLITE_OMIT_UTF16 -DSQLITE_OMIT_AUTHORIZATION -DSQLITE_OMIT_COMPLETE
        -DSQLITE_OMIT_TRACE -DSQLITE_OMIT_TCL_VARIABLE -DSQLITE_OMIT_COMPILEOPTION_DIAGS
        -DSQLITE_OMIT_AUTOVACUUM -DSQLITE_OMIT_BLOB_LITERAL
        -DSQLITE_ENABLE_FTS5
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

      DEMO_SYNC_PARTITIONS = [
        {
          "path" => "/email",
          "partitionParam" => "inbox",
          "partitionDefault" => "support",
          "partitionKey" => "mailbox_id",
          "scopeParam" => "member",
          "scopeDefault" => "maya",
          "scopeHeader" => "X-Instant-Record-Member",
          "valid" => "^[a-z]{1,32}$",
          "lookupParams" => %w[before thread],
          "preloadBefore" => { "idParam" => "before", "atParam" => "at", "type" => "MailEntry", "limit" => 50 },
          "shellPath" => "/email/shell"
        }
      ].freeze

      HOTWIRE_GEMS = %w[turbo-rails stimulus-rails].freeze
      CONTROLLER_CONFIG_FILES = %w[config/importmap.rb config/application.rb].freeze
      DIGEST_READ_CHUNK = 65_536
      DIGEST_READ_MODE = "rb".freeze
      PYC_SUFFIX = ".pyc".freeze
      ROOT_SLASH = "/".freeze
      DOT_REL = ".".freeze
      PARENT_DIR = "..".freeze
      PARENT_PREFIX = "../".freeze
      NULL_BYTE = "\0".freeze
      private_constant :HOTWIRE_GEMS, :CONTROLLER_CONFIG_FILES, :DIGEST_READ_CHUNK,
                       :DIGEST_READ_MODE, :PYC_SUFFIX, :ROOT_SLASH, :DOT_REL,
                       :PARENT_DIR, :PARENT_PREFIX, :NULL_BYTE

      attr_reader :workspace, :gem_root, :pipeline_dir, :build_dir, :toolchain, :runner

      def initialize(
        workspace:,
        gem_root:,
        toolchain:,
        app_source: nil,
        models: [],
        sync_windows: nil,
        endpoint: nil,
        mount_path: nil,
        baseline: nil,
        migration_paths: nil,
        island: nil,
        overrides: nil,
        shell_snapshot: nil,
        build_dir: nil,
        out: $stdout
      )
        @workspace = File.expand_path(workspace.to_s)
        @gem_root = File.expand_path(gem_root.to_s)
        @pipeline_dir = File.join(@gem_root, "compiled/pipeline")
        @build_dir = File.expand_path((build_dir || File.join(@workspace, ".build")).to_s)
        @toolchain = Toolchain.load(toolchain)
        @app_source = app_source ? File.expand_path(app_source.to_s) : nil
        @demo = @app_source.nil?
        @source_root = @app_source || File.join(@gem_root, "demo")
        @models = models
        @sync_windows = sync_windows
        @endpoint = (endpoint || ENV.fetch("SYNC_ENDPOINT", DEFAULT_SYNC_ENDPOINT)).to_s.sub(%r{/+\z}, "")
        @mount_path = (mount_path && !mount_path.to_s.empty?) ? mount_path.to_s.sub(%r{/+\z}, "") : "/instant_record"
        @baseline = baseline
        @migration_paths = migration_paths
        @island = island
        @overrides = overrides
        @shell_snapshot = shell_snapshot.nil? ? ENV.fetch("INSTANT_RECORD_SHELL_SNAPSHOT", "") : shell_snapshot.to_s
        @runner = Runner.new(build_dir: @build_dir)
        @out = out
      end

      def run
        FileUtils.mkdir_p(@build_dir)
        FileUtils.mkdir_p(@toolchain.fetch("CACHE"))
        ensure_schema_lock

        stamp = File.join(@build_dir, "stamp")
        wanted = input_digest
        output = File.join(@workspace, "web/dist")
        if build_current?(stamp, wanted, output)
          @out.puts "build is current"
          return Pathname(output)
        end
        File.delete(stamp) if File.exist?(stamp)

        path_env = spinel_path_env

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
        emit = File.join(@build_dir, "emit")
        tree = File.join(@build_dir, "wasm-tree")

        stage = stage_app(app, native: native)
        manifest = stage.manifest
        plan = resolve_migration_plan(stage)
        vendor_and_lint(app, native: native)
        emit_roundhouse(app, emit)

        shell_fingerprint = InstantRecord::Shell.fingerprint(
          models: EntryBuilder.app_models(manifest: manifest, models: @models),
          schema_path: File.join(@source_root, "db/schema.rb")
        )
        build_wasm_tree(
          app: app,
          emit: emit,
          tree: tree,
          manifest: manifest,
          plan: plan,
          shell_fingerprint: shell_fingerprint
        )

        { app: app, emit: emit, tree: tree, plan: plan, manifest: manifest, shell_fingerprint: shell_fingerprint }
      end

      def input_digest
        digest = Digest::SHA256.new
        update_config_digest(digest)
        update_files_digest(digest, collect_input_files)
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

      def warm_scripts(assets_dir, deferred_css: [])
        urls = []
        seen = Digest::SHA256.new
        deferred_css.each do |name|
          path = File.join(assets_dir, name)
          next unless File.file?(path)

          seen.update(name + short_file_digest(path))
          urls << "/assets/#{name}"
        end
        [
          [assets_dir, "/assets/"],
          [File.join(assets_dir, "controllers"), "/assets/controllers/"]
        ].each do |folder, prefix|
          each_js_file(folder) do |name, path|
            digest = short_file_digest(path)
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
        links.concat(worker_starts(File.join(dist, "harness")))

        assets_dir = File.join(dist, "assets")
        preloaded_css, deferred_css = split_stylesheets(assets_dir)
        links.concat(preloaded_css.map { |name| %(    <link rel="preload" as="style" fetchpriority="low" href="/assets/#{name}">) })
        links.concat(warm_scripts(assets_dir, deferred_css: deferred_css))
        return if links.empty?

        index_path = File.join(dist, "index.html")
        html = File.read(index_path)
        File.write(index_path, html.sub("  </head>") { "#{links.join("\n")}\n  </head>" })
      end

      private

      def ensure_schema_lock
        return if @demo || File.file?(SchemaLock.path(@app_source))

        SchemaLock.write!(
          root: @app_source,
          baseline: @baseline,
          migration_paths: @migration_paths
        )
      end

      def build_current?(stamp, wanted, output)
        File.file?(stamp) && File.read(stamp) == wanted && File.file?(File.join(output, "index.html"))
      end

      def spinel_path_env
        {
          "PATH" => [@toolchain.join("SPINEL_HOME", "bin"), ENV.fetch("PATH", "")].join(File::PATH_SEPARATOR),
          "WASI_SDK" => @toolchain.fetch("WASI_SDK")
        }
      end

      def stage_app(app, native:)
        AppStage.stage(
          source: @source_root,
          target: app,
          native: native,
          island: @island,
          overrides: @overrides,
          models: @demo ? nil : @models,
          migration_paths: @migration_paths,
          overlay_dir: @demo ? File.join(@pipeline_dir, "demo") : nil,
          manifest_path: File.join(@build_dir, Manifest::FILENAME)
        )
      end

      def resolve_migration_plan(stage)
        return DEMO_MIGRATION_PLAN if @demo

        verify_schema_lock!
        plan = BrowserMigrations.plan(
          root: @app_source,
          baseline: @baseline,
          migration_paths: @migration_paths,
          only_files: stage.manifest.island? ? stage.trace.migrations : nil
        )
        File.write(File.join(@build_dir, "browser-migrations.json"), JSON.generate(plan))
        plan
      end

      def verify_schema_lock!
        return unless File.file?(SchemaLock.path(@app_source))

        lock_report = SchemaLock.verify(
          root: @app_source,
          baseline: @baseline,
          migration_paths: @migration_paths,
          models: @models
        )
        raise BuildError, "Schema lockfile verification failed:\n#{lock_report}" unless lock_report.ok?
      end

      def vendor_and_lint(app, native:)
        vendor = GemVendor.new(
          gem_src: @gem_root,
          app_dir: app,
          demo: @demo,
          target: native ? :native : :wasm
        )
        vendor.run
        StaticLinter.check!(app, staged: true, server_only_constants: vendor.server_only_constants)
      end

      def emit_roundhouse(app, emit)
        clean(emit)
        @runner.run([@toolchain.fetch("ROUNDHOUSE_BIN"), "--target", "spinel", "-o", emit, app], log: "emit.log")
        version_controller_urls(app, emit)
        disable_jemalloc(emit)
      end

      def build_wasm_tree(app:, emit:, tree:, manifest:, plan:, shell_fingerprint:)
        clean(tree)
        EntryBuilder.write_wasm_entry(
          emit_dir: emit,
          demo: @demo,
          manifest: manifest,
          models: @models,
          sync_windows: @sync_windows,
          endpoint: @endpoint,
          mount_path: @mount_path,
          migration_plan: plan,
          pipeline_dir: @pipeline_dir,
          app_dir: app,
          shell_fingerprint: shell_fingerprint
        )
        WasmTree.build(source: emit, target: tree, demo: @demo)
      end

      def update_config_digest(digest)
        digest.update(@baseline.to_s) unless @demo
        [
          @demo ? "" : JSON.generate(Array(@models)),
          JSON.generate(@sync_windows || {}),
          @mount_path,
          @island.to_s,
          JSON.generate(@overrides || {}),
          @shell_snapshot
        ].each do |part|
          digest.update(part)
          digest.update(NULL_BYTE)
        end
      end

      def collect_input_files
        paths = []
        config_present = collect_explicit_input_files(paths)
        collect_override_input_files(paths, config_present: config_present)
        collect_directory_input_files(paths)
        paths.sort!
        paths.uniq!
        paths
      end

      def collect_explicit_input_files(paths)
        toolchain_path = File.expand_path(@toolchain.path)
        paths << toolchain_path if File.file?(toolchain_path)

        [
          File.join(@workspace, "web/index.html"),
          File.join(@workspace, "web/vite.config.js"),
          File.join(@workspace, "web/package.json"),
          File.join(@workspace, "web/package-lock.json"),
          File.join(@gem_root, "lib/instant_record.rb"),
          File.join(@gem_root, "sig/instant_record/native.rbs"),
          File.join(@gem_root, "sig/instant_record/native_host.rbs"),
          File.join(@gem_root, "sig/instant_record/inertia.rbs")
        ].each do |path|
          paths << path if File.file?(path)
        end

        unless @demo
          lock_path = SchemaLock.path(@source_root)
          paths << lock_path if File.file?(lock_path)
        end

        AppStage::FILES.each do |name|
          path = File.join(@source_root, name)
          paths << path if File.file?(path)
        end

        config_path = File.join(@source_root, Manifest::CONFIG_FILE)
        config_present = File.file?(config_path)
        paths << config_path if config_present
        config_present
      end

      def collect_override_input_files(paths, config_present:)
        return if !config_present && (@overrides.nil? || (@overrides.is_a?(Hash) && @overrides.empty?))

        config_overrides = Manifest.merge_overrides(
          config_present ? Manifest.load_config(@source_root, island: @island) : nil,
          @overrides
        )
        config_overrides[:include]["files"].each do |rel|
          candidate = File.expand_path(rel.delete_prefix(ROOT_SLASH), @source_root)
          paths << candidate if path_within?(candidate, @source_root) && File.file?(candidate)
        end
      end

      def input_directories
        dirs = [
          @pipeline_dir,
          File.join(@workspace, "web/src"),
          File.join(@gem_root, "lib/instant_record"),
          File.join(@gem_root, "app/models/instant_record"),
          File.join(@source_root, "app"),
          File.join(@source_root, "config/routes"),
          File.join(@source_root, "config/locales")
        ]
        unless @demo
          dirs << File.join(@source_root, "db/browser_migrate")
          dirs.concat(Array(@migration_paths || [File.join(@source_root, "db/migrate")]))
        end
        dirs
      end

      def collect_directory_input_files(paths)
        visited_dirs = {}
        stack = []
        input_directories.each do |dir|
          raw = dir.to_s
          next unless File.directory?(raw)

          if raw.include?(PARENT_DIR) || raw.start_with?("~")
            walk_directory_expanding(raw, paths)
            next
          end

          root = File.expand_path(raw)
          next if visited_dirs[root]

          visited_dirs[root] = true
          stack << root
          while (cur = stack.pop)
            prefix = cur == ROOT_SLASH ? ROOT_SLASH : "#{cur}/"
            begin
              Dir.each_child(cur) do |name|
                path = "#{prefix}#{name}"
                begin
                  stat = File.lstat(path)
                rescue SystemCallError
                  next
                end

                if stat.file?
                  paths << path unless name.end_with?(PYC_SUFFIX)
                elsif stat.directory?
                  unless visited_dirs[path]
                    visited_dirs[path] = true
                    stack << path
                  end
                elsif stat.symlink?
                  paths << path if !name.end_with?(PYC_SUFFIX) && File.file?(path)
                end
              end
            rescue SystemCallError
              next
            end
          end
        end
      end

      def walk_directory_expanding(root, paths)
        stack = [root]
        while (cur = stack.pop)
          prefix = cur.end_with?(ROOT_SLASH) ? cur : "#{cur}/"
          begin
            Dir.each_child(cur) do |name|
              path = "#{prefix}#{name}"
              begin
                stat = File.lstat(path)
              rescue SystemCallError
                next
              end

              if stat.file?
                paths << File.expand_path(path) unless name.end_with?(PYC_SUFFIX)
              elsif stat.directory?
                stack << path
              elsif stat.symlink?
                paths << File.expand_path(path) if !name.end_with?(PYC_SUFFIX) && File.file?(path)
              end
            end
          rescue SystemCallError
            next
          end
        end
      end

      def gem_root_ancestors
        @gem_root_ancestors ||= begin
          ancestors = []
          cur = @gem_root
          depth = 0
          until cur == ROOT_SLASH
            parent = File.dirname(cur)
            break if parent == cur

            depth += 1
            prefix = parent == ROOT_SLASH ? ROOT_SLASH : "#{parent}/"
            ups = PARENT_PREFIX * depth
            ups_exact = depth == 1 ? PARENT_DIR : "#{PARENT_PREFIX * (depth - 1)}#{PARENT_DIR}"
            ancestors << [prefix, prefix.bytesize, ups, parent, ups_exact, "#{cur}/", cur]
            cur = parent
          end
          ancestors
        end
      end

      def update_files_digest(digest, paths)
        buf = String.new(capacity: DIGEST_READ_CHUNK, encoding: Encoding::BINARY)

        if @gem_root == ROOT_SLASH
          paths.each do |path|
            if path == ROOT_SLASH
              digest.update(DOT_REL)
            else
              digest.update(path.byteslice(1, path.bytesize - 1))
            end
            update_file_content_digest(digest, path, buf)
          end
          return
        end

        gem_prefix = "#{@gem_root}/"
        gem_prefix_len = gem_prefix.bytesize
        ancestors = nil
        cached_anc = nil

        paths.each do |path|
          if path.start_with?(gem_prefix)
            digest.update(path.byteslice(gem_prefix_len, path.bytesize - gem_prefix_len))
          elsif path == @gem_root
            digest.update(DOT_REL)
          elsif cached_anc && path.start_with?(cached_anc[0]) && !path.start_with?(cached_anc[5]) && path != cached_anc[6] && path != cached_anc[3]
            digest.update(cached_anc[2])
            digest.update(path.byteslice(cached_anc[1], path.bytesize - cached_anc[1]))
          else
            ancestors ||= gem_root_ancestors
            matched = false
            ancestors.each do |anc|
              if path == anc[3]
                digest.update(anc[4])
                matched = true
                break
              elsif path.start_with?(anc[0])
                cached_anc = anc
                digest.update(anc[2])
                digest.update(path.byteslice(anc[1], path.bytesize - anc[1]))
                matched = true
                break
              end
            end
            digest.update(Pathname(path).relative_path_from(Pathname(@gem_root)).to_s) unless matched
          end

          update_file_content_digest(digest, path, buf)
        end
      end

      def update_file_content_digest(digest, path, buf)
        File.open(path, DIGEST_READ_MODE) do |file|
          while file.read(DIGEST_READ_CHUNK, buf)
            digest.update(buf)
            break if buf.bytesize < DIGEST_READ_CHUNK
          end
        end
      end

      def short_file_digest(path)
        Digest::SHA256.file(path).hexdigest[0, 10]
      end

      def path_within?(path, root)
        path.start_with?("#{root}#{File::SEPARATOR}")
      end

      def each_js_file(dir)
        return unless File.directory?(dir)

        Dir.children(dir).sort.each do |name|
          path = File.join(dir, name)
          yield name, path if name.end_with?(".js") && File.file?(path)
        end
      end

      # Started here, not preloaded: a modulepreload is a module load in the page, after
      # which Firefox refuses the import map of the app's own page (compiled/web/vite.config.js).
      def worker_starts(harness_dir)
        return [] unless File.directory?(harness_dir)

        workers = Dir.children(harness_dir).sort.select { |name| name.start_with?("worker-") && name.end_with?(".js") }
        workers.map do |name|
          %(    <script>try { window.__worker = new Worker("/harness/#{name}", { type: "module" }); } catch (error) {}</script>)
        end
      end

      def split_stylesheets(assets_dir)
        return [[], []] unless File.directory?(assets_dir)

        css_files = Dir.children(assets_dir).sort.select { |name| name.end_with?(".css") }
        css_files.partition do |name|
          stem = File.basename(name, ".css").sub(/-[0-9a-f]{8,}\z/, "")
          css_files.length <= 3 || CORE_PRELOAD_STYLES.include?(stem)
        end
      end

      def clean(path)
        expanded = File.expand_path(path)
        raise BuildError, "Refusing to clean outside #{@build_dir}: #{expanded}" unless path_within?(expanded, @build_dir)

        FileUtils.rm_rf(expanded)
      end

      def version_controller_urls(app, emit)
        controller_dir = File.join(app, "app/javascript/controllers")
        versions = {}
        each_js_file(controller_dir) { |name, file| versions[name] = short_file_digest(file) }
        return if versions.empty?

        CONTROLLER_CONFIG_FILES.each do |config|
          path = File.join(emit, config)
          next unless File.file?(path)

          source = File.read(path)
          updated = source
          versions.each do |name, version|
            asset = "/assets/controllers/#{name}"
            updated = updated.gsub(asset, "#{asset}?v=#{version}")
          end
          File.write(path, updated) if updated != source
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
            *flags,
            "main_wasm.rb", "-o", app_c
          ],
          cwd: tree,
          env: path_env.merge("CPATH" => sqlite_src),
          log: "spinel.log"
        )

        spinel_home = @toolchain.fetch("SPINEL_HOME")
        clang = @toolchain.join("WASI_SDK", "bin/clang")
        pkg_objs = SPINEL_PACKAGES.map { |pkg| File.join(spinel_home, "packages", pkg, "sp_#{pkg}_wasi.o") }

        @runner.run(
          [
            clang, *WASI_CFLAGS, "-mexec-model=reactor", WASM_OPT_LEVEL, *REACTOR_SIZE_CFLAGS,
            "-Wno-all", "-ffp-contract=off",
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
        stripped = File.join(tree, "build/app.stripped.wasm")
        @runner.run([@toolchain.join("WASI_SDK", "bin/llvm-strip"), "-o", stripped, wasm])
        final = stripped

        wasm_opt = Toolchain.which("wasm-opt")
        if wasm_opt
          opted = File.join(tree, "build/app.opt.wasm")
          @runner.run([wasm_opt, WASM_OPT_PASS, *WASM_OPT_FEATURES, final, "-o", opted], cwd: tree, log: "wasm-opt.log")
          final = opted
        end
        final
      end

      def ensure_web_node_modules(web)
        modules = File.join(web, "node_modules")
        configured = @toolchain["WEB_NODE_MODULES"]
        if File.symlink?(modules)
          repoint_node_modules_symlink(modules, configured)
        elsif !File.exist?(modules)
          if configured.nil? || configured.empty? || !File.directory?(configured)
            raise BuildError, "WEB_NODE_MODULES is missing (#{configured || 'unset'}). Install the web dependencies from compiled/web/package.json with `npm ci` and set WEB_NODE_MODULES in #{@toolchain.path}."
          end
          File.symlink(configured, modules)
        end
      end

      def repoint_node_modules_symlink(modules, configured)
        if configured && !configured.empty? && File.readlink(modules) != configured
          unless File.directory?(configured)
            raise BuildError, "WEB_NODE_MODULES does not exist at #{configured}. Install the web dependencies with `npm ci` and run `bin/rails instant_record:doctor`."
          end
          File.delete(modules)
          File.symlink(configured, modules)
        end
        return if File.directory?(modules)

        raise BuildError, "WEB_NODE_MODULES symlink target does not exist (#{File.readlink(modules)}). Install the web dependencies with `npm ci` and run `bin/rails instant_record:doctor`."
      end

      def build_web_site(emitted, final_wasm, wanted)
        web = File.join(@workspace, "web")
        ensure_web_node_modules(web)

        digest = short_file_digest(final_wasm)
        dist = File.join(@build_dir, "site")

        @runner.run(
          ["npx", "vite", "build", "--outDir", dist, "--emptyOutDir"],
          cwd: web,
          env: vite_build_env(emitted, wasm_digest: digest, wanted: wanted),
          log: "vite.log"
        )

        write_release_artifacts(dist: dist, manifest: emitted[:manifest], final_wasm: final_wasm, wasm_digest: digest, wanted: wanted)
        stage_site_assets(dist, emitted[:app], emitted[:emit])
        copy_site_extras(dist, emitted[:app], wanted)
        inject_preloads(dist, emitted[:app])
        precompress(dist)
        [dist, digest]
      end

      def vite_build_env(emitted, wasm_digest:, wanted:)
        plan = emitted[:plan]
        manifest = emitted[:manifest]
        schema_source = File.read(File.join(emitted[:app], "db/schema.rb"))
        trace_schema = InstantRecord::Trace::SchemaExtractor.from_schema_rb(schema_source)
        schema_digest = Digest::SHA256.file(File.join(emitted[:emit], "config/schema.rb")).hexdigest

        {
          "VITE_WASM_URL" => "/app-#{wasm_digest}.wasm",
          "VITE_SHELL_FINGERPRINT" => emitted[:shell_fingerprint],
          "VITE_SHELL_SNAPSHOT" => @shell_snapshot,
          "VITE_SYNC_PARTITIONS" => @demo ? JSON.generate(DEMO_SYNC_PARTITIONS) : "[]",
          "VITE_SYNC_ENDPOINT" => @endpoint,
          "VITE_MOUNT_PATH" => @mount_path,
          "VITE_SOURCE_VERSION" => wanted[0, 12],
          "VITE_SCHEMA_VERSION" => plan["version"].to_s,
          "VITE_SCHEMA_BASELINE" => plan["baseline"].nil? ? "" : plan["baseline"].to_s,
          "VITE_MIGRATION_HISTORY" => JSON.generate(plan["history"] || {}),
          "VITE_SCHEMA_DIGEST" => schema_digest,
          "VITE_MANIFEST" => manifest ? manifest.to_compact_json : "{}",
          "VITE_TRACE_SCHEMA" => JSON.generate(trace_schema)
        }
      end

      def write_release_artifacts(dist:, manifest:, final_wasm:, wasm_digest:, wanted:)
        File.write(File.join(dist, "instant-record-release.json"), JSON.generate("version" => wanted))
        File.write(File.join(dist, Manifest::FILENAME), manifest.to_json) if manifest
        FileUtils.cp(final_wasm, File.join(dist, "app-#{wasm_digest}.wasm"))
      end

      def stage_site_assets(dist, app, emit)
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
      end

      def copy_site_extras(dist, app, wanted)
        if @demo
          SourcePages.write(
            app_dir: app,
            dist_dir: dist,
            version: wanted[0, 12],
            demo_dir: @source_root,
            pipeline_dir: @pipeline_dir
          )
        end

        shell_worker = File.join(@source_root, "app/views/pwa/service-worker.js")
        FileUtils.cp(shell_worker, File.join(dist, "service-worker.js")) if File.file?(shell_worker)
      end

      # Copies for CompiledSite to serve. Node is already needed by the web build.
      def precompress(dist)
        @runner.run(["node", "-e", PRECOMPRESS_JS, dist], log: "precompress.log")
      end

      def copy_hotwire_assets(assets)
        found = {}
        hotwire_asset_roots.each do |root|
          missing = HOTWIRE_ASSETS - found.keys
          break if missing.empty?

          collect_matching_assets(root, missing, found)
        end

        HOTWIRE_ASSETS.each do |name|
          FileUtils.cp(found[name], assets) if found[name]
        end
      end

      def hotwire_asset_roots
        [@toolchain["RAILS_GEMS"], *HOTWIRE_GEMS.map { |name| Gem.loaded_specs[name]&.full_gem_path }].compact
      end

      def collect_matching_assets(root, names, found)
        return unless File.directory?(root)

        pattern = "**/{#{names.join(',')}}"
        Dir.glob(pattern, base: root).sort.each do |rel|
          name = File.basename(rel)
          found[name] ||= File.join(root, rel)
        end
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
