require "fileutils"
require "json"
require "pathname"

module InstantRecord
  # Stage the packaged compiler under the host app's tmp directory. A build never
  # writes into an installed gem or replaces the host's public assets.
  class Compiler
    def self.build(root:, models:, toolchain:, endpoint:)
      root = Pathname(root).realpath
      gem_root = Pathname(__dir__).join("../..").realpath
      toolchain = Pathname(toolchain).expand_path
      raise ArgumentError, "Missing compiler toolchain file: #{toolchain}" unless toolchain.file?
      workspace = root.join("tmp/instant_record/compiled")
      FileUtils.mkdir_p(workspace)
      File.open(workspace.join(".lock"), "a") do |lock|
        lock.flock(File::LOCK_EX)
        package = gem_root.join("compiled")
        # Remove prior compiler sources so a removed overlay cannot survive a gem upgrade.
        FileUtils.rm_rf(workspace.join("pipeline"))
        FileUtils.cp_r(package.join("pipeline"), workspace)
        web = workspace.join("web")
        FileUtils.mkdir_p(web)
        FileUtils.rm_rf(web.join("src"))
        %w[index.html vite.config.js package.json package-lock.json src].each do |part|
          FileUtils.cp_r(package.join("web", part), web)
        end
        demo = root == gem_root.join("demo")
        env = {
          "GEM_SRC" => gem_root.to_s,
          "INSTANT_RECORD_APP" => demo ? nil : root.to_s,
          "INSTANT_RECORD_MODELS" => JSON.generate(models),
          "INSTANT_RECORD_TOOLCHAIN" => toolchain.to_s,
          "SYNC_ENDPOINT" => endpoint,
          "PYTHONDONTWRITEBYTECODE" => "1"
        }
        ok = system(env, "python3", workspace.join("pipeline/build.py").to_s)
        raise "InstantRecord compilation failed. Build logs are in #{workspace.join('.build')}." unless ok
      end
      workspace.join("web/dist")
    end
  end
end
