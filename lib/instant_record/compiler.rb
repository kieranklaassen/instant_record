require "fileutils"
require "json"
require "pathname"
require "tmpdir"
require_relative "compiler/runner"
require_relative "compiler/toolchain"
require_relative "compiler/path_scrubber"
require_relative "compiler/browser_migrations"
require_relative "compiler/schema_lock"
require_relative "compiler/manifest"
require_relative "compiler/route_analyzer"
require_relative "compiler/reachability_tracer"
require_relative "compiler/ast_lowerer"
require_relative "compiler/host_adapters"
require_relative "compiler/static_linter"
require_relative "compiler/app_stage"
require_relative "compiler/gem_vendor"
require_relative "compiler/entry_builder"
require_relative "compiler/native_contracts"
require_relative "compiler/swift_codegen"
require_relative "compiler/kotlin_codegen"
require_relative "compiler/wasm_tree"
require_relative "compiler/source_pages"
require_relative "compiler/wasm_build"
require_relative "compiler/native_build"
require_relative "compiler/fts5_smoke"

module InstantRecord
  # Compiles a Rails app (or this repository's demo) into a static Wasm browser
  # site or native iOS/macOS static libraries in-process from Ruby. A build never
  # writes into an installed gem or replaces the host's public assets until publish.
  class Compiler
    WEB_PARTS = %w[index.html vite.config.js package.json package-lock.json src].freeze

    def self.gem_root
      Pathname(__dir__).join("../..").realpath
    end

    def self.demo_toolchain(toolchain = nil)
      toolchain || ENV.fetch("INSTANT_RECORD_TOOLCHAIN") { gem_root.join("compiled/toolchain.env").to_s }
    end

    def self.build(root:, toolchain:, endpoint:, models: nil, sync_windows: nil, mount_path: nil, baseline: nil, migration_paths: nil, island: nil, overrides: nil, shell_snapshot: nil)
      with_workspace(root: root, toolchain: toolchain, stage_web: true) do |shared|
        WasmBuild.new(
          **shared,
          models: models,
          sync_windows: sync_windows,
          endpoint: endpoint,
          mount_path: mount_path,
          baseline: baseline,
          migration_paths: migration_paths || shared[:migration_paths],
          island: island,
          overrides: overrides,
          shell_snapshot: shell_snapshot
        ).run
      end
    end

    # The same app as libraries a native host links: for this machine, or
    # with target "iphonesimulator" or "iphoneos" for the iOS simulator or
    # an iPhone. Returns the folder that holds them.
    def self.build_native(
      root:,
      toolchain:,
      endpoint:,
      models: nil,
      target: nil,
      sync_windows: nil,
      mount_path: nil,
      baseline: nil,
      migration_paths: nil,
      island: nil,
      overrides: nil,
      swift_out: nil,
      kotlin: false,
      kotlin_out: nil,
      kotlin_package: "dev.instantrecord.contracts",
      out: $stdout
    )
      with_workspace(root: root, toolchain: toolchain, stage_web: false) do |shared|
        NativeBuild.new(
          **shared,
          models: models,
          sync_windows: sync_windows,
          endpoint: endpoint,
          mount_path: mount_path,
          target: target,
          baseline: baseline,
          migration_paths: migration_paths || shared[:migration_paths],
          island: island,
          overrides: overrides,
          swift_out: swift_out,
          kotlin: kotlin,
          kotlin_out: kotlin_out,
          kotlin_package: kotlin_package,
          out: out
        ).run
      end
    end

    # Extract typed prop/action contracts from app/screens via Prism and emit
    # Swift (and optionally Kotlin) source files without running a C build.
    def self.generate_native_contracts(screens_dir:, swift_out: nil, kotlin_out: nil, kotlin_package: "dev.instantrecord.contracts", kotlin_serializable: true)
      contracts = NativeContracts.extract_dir(screens_dir)
      written = {}
      return { contracts: contracts, written: written } if contracts.empty?

      if swift_out
        path = File.expand_path(swift_out.to_s)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, SwiftCodegen.generate(contracts))
        written[:swift] = Pathname(path)
      end

      if kotlin_out
        path = File.expand_path(kotlin_out.to_s)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, KotlinCodegen.generate(contracts, package: kotlin_package, serializable: kotlin_serializable))
        written[:kotlin] = Pathname(path)
      end

      { contracts: contracts, written: written }
    end

    # Build the repository's own demo into compiled/web/dist.
    def self.build_demo(toolchain: nil, endpoint: nil, shell_snapshot: nil, island: nil)
      WasmBuild.new(
        workspace: gem_root.join("compiled"),
        gem_root: gem_root,
        toolchain: demo_toolchain(toolchain),
        endpoint: endpoint,
        shell_snapshot: shell_snapshot,
        island: island
      ).run
    end

    # Build the repository's own demo into compiled/.build-native[/target].
    def self.build_demo_native(target: nil, toolchain: nil, endpoint: nil, island: nil, out: $stdout)
      NativeBuild.new(
        workspace: gem_root.join("compiled"),
        gem_root: gem_root,
        toolchain: demo_toolchain(toolchain),
        endpoint: endpoint,
        target: target,
        island: island,
        out: out
      ).run
    end

    # Analyze a Rails app's local-first island(s) and return its Manifest without compiling.
    def self.manifest(root:, island: nil, overrides: nil, native: false, migration_paths: nil)
      AppStage.analyze(
        source: root,
        native: native,
        island: island,
        overrides: overrides,
        migration_paths: migration_paths
      ).manifest
    end

    def self.doctor(toolchain:, target: :wasm, web_dir: nil, root: nil, app_root: nil, baseline: nil, migration_paths: nil, models: nil, island: nil, overrides: nil)
      report = Toolchain.load(toolchain).doctor(target: target, web_dir: web_dir)
      if app_root
        report = report.with_lint(lint(app_root, staged: false, island: island, overrides: overrides))
      end
      schema_root = root || app_root
      if schema_root && File.file?(File.join(schema_root.to_s, "db/schema.rb"))
        schema_report = SchemaLock.verify(
          root: schema_root,
          baseline: baseline,
          migration_paths: migration_paths,
          models: models
        )
        schema_report.checks.each do |check|
          report.checks << Toolchain::Check.new(
            name: "schema:#{check.name}",
            status: check.ok? ? :ok : :error,
            detail: check.detail
          )
        end
      end
      report
    end

    def self.lock_schema(root:, baseline: nil, migration_paths: nil, force: false)
      SchemaLock.write!(root: root, baseline: baseline, migration_paths: migration_paths, force: force)
    end

    def self.verify_schema(root:, baseline: nil, migration_paths: nil, models: nil)
      SchemaLock.verify(root: root, baseline: baseline, migration_paths: migration_paths, models: models)
    end

    def self.lint(root, staged: false, exclude: nil, island: nil, overrides: nil)
      resolved = Pathname(root)
      only_files = nil
      if !staged && exclude.nil? && resolved.join("config/routes.rb").file?
        analysis = AppStage.analyze(source: resolved, native: true, island: island, overrides: overrides)
        if analysis.manifest.island?
          staged_map = analysis.manifest.staged
          only_files = (
            Array(staged_map["controllers"]) +
            Array(staged_map["models"]) +
            Array(staged_map["helpers"]) +
            Array(staged_map["screens"]) +
            Array(staged_map["files"]) +
            %w[config/application.rb config/importmap.rb]
          ).select { |rel| rel.end_with?(".rb") }.uniq
        end
      end
      StaticLinter.lint(root, staged: staged, exclude: Array(exclude), only_files: only_files)
    end

    def self.scrub_path(path, prefix)
      PathScrubber.scrub(path, prefix)
    end

    def self.verify_fts5(toolchain: nil, target: :native)
      Fts5Smoke.run(toolchain: demo_toolchain(toolchain), target: target)
    end

    def self.with_workspace(root:, toolchain:, stage_web:)
      app_root = Pathname(root).realpath
      parsed_toolchain = Toolchain.load(toolchain)
      workspace = app_root.join("tmp/instant_record/compiled")
      FileUtils.mkdir_p(workspace)

      File.open(workspace.join(".lock"), "a") do |lock|
        lock.flock(File::LOCK_EX)
        if stage_web
          package = gem_root.join("compiled/web")
          web = workspace.join("web")
          FileUtils.mkdir_p(web)
          FileUtils.rm_rf(web.join("src"))
          WEB_PARTS.each do |part|
            FileUtils.cp_r(package.join(part), web)
          end
        end
        demo = app_root == gem_root.join("demo")
        yield(
          workspace: workspace,
          gem_root: gem_root,
          toolchain: parsed_toolchain,
          app_source: demo ? nil : app_root.to_s,
          migration_paths: [app_root.join("db/migrate").to_s]
        )
      end
    end
    private_class_method :with_workspace

    def self.publish(root)
      workspace = Pathname(root).join("tmp/instant_record/compiled")
      unless workspace.directory?
        raise BuildError, "Compiled workspace does not exist at #{workspace}. Run a build before publishing."
      end

      public_root = Pathname(root).join("public/instant_record_compiled")
      File.open(workspace.join(".lock"), "a") do |lock|
        lock.flock(File::LOCK_EX)
        dist = workspace.join("web/dist")
        unless dist.directory?
          raise BuildError, "Compiled dist directory does not exist at #{dist}. Run a build before publishing."
        end

        release_file = dist.join("instant-record-release.json")
        unless release_file.file?
          raise BuildError, "Compiled release metadata is missing at #{release_file}. Run a build before publishing."
        end

        release =
          begin
            JSON.parse(release_file.read)
          rescue JSON::ParserError => e
            raise BuildError, "Invalid compiled release JSON in #{release_file}: #{e.message}"
          end

        version = release.is_a?(Hash) ? release["version"] : nil
        unless version.is_a?(String) && version.match?(/\A[0-9a-f]{64}\z/)
          raise BuildError, "Invalid compiled release version"
        end

        FileUtils.mkdir_p(public_root)
        destination = public_root.join(version)
        unless destination.directory?
          Dir.mktmpdir(".release-", public_root) do |temp|
            staged = Pathname(temp).join("site")
            FileUtils.cp_r(dist, staged)
            File.rename(staged, destination)
          end
        end
        Dir.mktmpdir(".publish-", public_root) do |temp|
          link = Pathname(temp).join("current")
          File.symlink(version, link)
          File.rename(link, public_root.join("current"))
        end
      end
    end
  end
end
