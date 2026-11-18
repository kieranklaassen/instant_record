namespace :instant_record do
  desc "Compile this Rails app to a static browser site using Roundhouse, Spinel and SQLite"
  task compile: :environment do
    require "instant_record/compiler"
    Rails.application.eager_load!
    output = InstantRecord::Compiler.build(
      root: Rails.root,
      models: InstantRecord.syncable_models.map(&:name),
      toolchain: ENV.fetch("INSTANT_RECORD_TOOLCHAIN") { Rails.root.join("config/instant_record_toolchain.env") },
      endpoint: ENV.fetch("SYNC_ENDPOINT") { Rails.application.config.instant_record.mount_path || InstantRecord::DEFAULT_MOUNT_PATH },
      baseline: Rails.application.config.instant_record.compiled_migration_baseline,
      migration_paths: Rails.application.config.paths["db/migrate"].existent
    )
    puts "Compiled browser site: #{output}"
  end

  desc "Build the browser bundle: compiles the Ruby wasm core (once) and packs app.wasm"
  task :build do
    require "wasmify-rails"

    # wasmify:pack precompiles assets in a subprocess; this flag stops the
    # assets:precompile enhancement below from recursing back into this task.
    ENV["INSTANT_RECORD_SKIP_BUILD"] = "1"

    core = File.join(Wasmify::Rails.config.tmp_dir, "ruby-core.wasm")
    Rake::Task["wasmify:build:core"].invoke unless File.exist?(core)
    Rake::Task["wasmify:pack"].invoke
    Rake::Task["instant_record:stamp_sw"].invoke
  end

  # Stamp the app.wasm digest into the service worker so its bytes change on
  # every rebuild. The browser's update check then installs the new worker,
  # which claims open tabs and reloads them onto the new bundle — without
  # this, installed clients keep running the old VM indefinitely.
  desc "Stamp the current app.wasm digest into pwa/rails.sw.js"
  task :stamp_sw do
    require "digest"

    root = defined?(Rails) && Rails.respond_to?(:root) && Rails.root ? Rails.root : Pathname.new(Dir.pwd)
    sw = root.join("pwa/rails.sw.js")
    wasm = root.join("pwa/public/app.wasm")
    next unless File.exist?(sw) && File.exist?(wasm)

    version = Digest::SHA256.file(wasm).hexdigest[0, 12]
    contents = File.read(sw)
    stamped = contents
      .sub(/__INSTANT_RECORD_BUILD_VERSION__/, version)
      .gsub(/const BUILD_VERSION = "[0-9a-f]{12}";/, %(const BUILD_VERSION = "#{version}";))
    File.write(sw, stamped)
    puts "Stamped service worker build version: #{version}"
  end
end

# Opt-in deploy hook: build the browser bundle during assets:precompile.
#
#   # config/application.rb
#   config.instant_record.build_on_precompile = true
#
# Off by default: the build needs the wasm toolchain and network access for
# ruby.wasm artifacts, which not every deploy environment has.
Rake::Task.define_task("assets:precompile").enhance do
  next if ENV["INSTANT_RECORD_SKIP_BUILD"]
  case Rails.application.config.instant_record.build_on_precompile
  when :compiled
    Rake::Task["instant_record:compile"].invoke
    InstantRecord::Compiler.publish(Rails.root)
  when true
    Rake::Task["instant_record:build"].invoke
  when false, nil
    # The host app manages its own build.
  else
    raise ArgumentError, "build_on_precompile must be false, true, or :compiled"
  end
end
