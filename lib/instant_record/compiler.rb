require "fileutils"
require "json"
require "pathname"
require "tmpdir"
require_relative "compiler/runner"
require_relative "compiler/toolchain"
require_relative "compiler/path_scrubber"
require_relative "compiler/browser_migrations"
require_relative "compiler/app_stage"
require_relative "compiler/gem_vendor"
require_relative "compiler/entry_builder"
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

    def self.build(root:, models:, toolchain:, endpoint:, sync_windows: nil, mount_path: nil, baseline: nil, migration_paths: nil)
      with_workspace(root: root, toolchain: toolchain, stage_web: true) do |shared|
        WasmBuild.new(
          **shared,
          models: models,
          sync_windows: sync_windows,
          endpoint: endpoint,
          mount_path: mount_path,
          baseline: baseline,
          migration_paths: migration_paths || shared[:migration_paths]
        ).run
      end
    end

    # The same app as libraries a native host links: for this machine, or
    # with target "iphonesimulator" or "iphoneos" for the iOS simulator or
    # an iPhone. Returns the folder that holds them.
    def self.build_native(root:, models:, toolchain:, endpoint:, target: nil, sync_windows: nil, mount_path: nil, baseline: nil, migration_paths: nil)
      with_workspace(root: root, toolchain: toolchain, stage_web: false) do |shared|
        NativeBuild.new(
          **shared,
          models: models,
          sync_windows: sync_windows,
          endpoint: endpoint,
          mount_path: mount_path,
          target: target,
          baseline: baseline,
          migration_paths: migration_paths || shared[:migration_paths]
        ).run
      end
    end

    # Build the repository's own demo into compiled/web/dist.
    def self.build_demo(toolchain: nil, endpoint: nil, shell_snapshot: nil)
      WasmBuild.new(
        workspace: gem_root.join("compiled"),
        gem_root: gem_root,
        toolchain: demo_toolchain(toolchain),
        endpoint: endpoint,
        shell_snapshot: shell_snapshot
      ).run
    end

    # Build the repository's own demo into compiled/.build-native[/target].
    def self.build_demo_native(target: nil, toolchain: nil, endpoint: nil)
      NativeBuild.new(
        workspace: gem_root.join("compiled"),
        gem_root: gem_root,
        toolchain: demo_toolchain(toolchain),
        endpoint: endpoint,
        target: target
      ).run
    end

    def self.doctor(toolchain:, target: :wasm, web_dir: nil)
      Toolchain.load(toolchain).doctor(target: target, web_dir: web_dir)
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
      public_root = Pathname(root).join("public/instant_record_compiled")
      FileUtils.mkdir_p(public_root)
      File.open(workspace.join(".lock"), "a") do |lock|
        lock.flock(File::LOCK_EX)
        dist = workspace.join("web/dist")
        version = JSON.parse(dist.join("instant-record-release.json").read).fetch("version")
        raise "Invalid compiled release version" unless version.match?(/\A[0-9a-f]{64}\z/)

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
