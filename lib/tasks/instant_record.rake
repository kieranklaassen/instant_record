namespace :instant_record do
  toolchain_path = lambda do
    ENV.fetch("INSTANT_RECORD_TOOLCHAIN") { Rails.root.join("config/instant_record_toolchain.env") }
  end

  require_toolchain = lambda do |path|
    abort "No toolchain file at #{path}. Run bin/rails generate instant_record:install, or set INSTANT_RECORD_TOOLCHAIN." unless File.file?(path)
  end

  # What both builds are told about this app.
  compiler_options = lambda do
    require "instant_record/compiler"
    Rails.application.eager_load!
    models = InstantRecord.syncable_models
    mount_path = Rails.application.config.instant_record.mount_path || InstantRecord::DEFAULT_MOUNT_PATH
    sync_windows = models.each_with_object({}) do |model, map|
      window = model.instant_record_sync_window
      next unless window

      map[model.name] = { limit: window.limit, partition_by: window.partition_by }
    end
    {
      root: Rails.root,
      models: models.map(&:name),
      sync_windows: sync_windows,
      toolchain: toolchain_path.call,
      endpoint: ENV.fetch("SYNC_ENDPOINT") { mount_path },
      mount_path: mount_path,
      baseline: Rails.application.config.instant_record.compiled_migration_baseline,
      migration_paths: Rails.application.config.paths["db/migrate"].existent,
      island: ENV["INSTANT_RECORD_ISLAND"].presence || Rails.application.config.instant_record.island,
      overrides: Rails.application.config.instant_record.include
    }
  end

  desc "Print the canonical instant_record.manifest.json for this app's local-first island"
  task :manifest, [:island] => :environment do |_task, args|
    require "instant_record/compiler"
    manifest = InstantRecord::Compiler.manifest(
      root: Rails.root,
      island: args[:island].presence || ENV["INSTANT_RECORD_ISLAND"].presence || Rails.application.config.instant_record.island,
      overrides: Rails.application.config.instant_record.include,
      migration_paths: Rails.application.config.paths["db/migrate"].existent
    )
    puts manifest.to_json
  end

  desc "Compile this Rails app to a static browser site using Roundhouse, Spinel and SQLite"
  task compile: :environment do
    # The options first: asking for them is what loads the compiler.
    options = compiler_options.call
    require_toolchain.call(options[:toolchain])
    output = InstantRecord::Compiler.build(**options)
    puts "Compiled browser site: #{output}"
  rescue InstantRecord::Compiler::BuildError, ArgumentError => e
    abort e.message
  end

  desc "Build the compiled browser site"
  task build: :compile

  desc "Build this Rails app, with its app/screens, as libraries a native app links: instant_record:native[iphonesimulator] or [iphoneos]"
  task :native, [:target] => :environment do |_task, args|
    options = compiler_options.call
    require_toolchain.call(options[:toolchain])
    output = InstantRecord::Compiler.build_native(**options, target: args[:target])
    puts "Native libraries: #{output}"
  rescue InstantRecord::Compiler::BuildError, ArgumentError => e
    abort e.message
  end

  desc "Run the local MCP stdio server or offline CLI around the compiled native host (pass CLI args after `--`)"
  task mcp: :environment do
    require "instant_record/compiler"
    require "instant_record/mcp"

    Rails.application.eager_load!
    mount_path = Rails.application.config.instant_record.mount_path || InstantRecord::DEFAULT_MOUNT_PATH
    default_endpoint =
      if mount_path.to_s.start_with?("http://", "https://")
        mount_path.to_s
      else
        "http://127.0.0.1:#{ENV.fetch('PORT', '3000')}#{mount_path}"
      end

    screens = InstantRecord::Compiler::EntryBuilder.discover_screens(Rails.root.to_s).map(&:first)
    models = InstantRecord.syncable_models.map(&:name)
    builder = lambda do
      options = compiler_options.call
      require_toolchain.call(options[:toolchain])
      InstantRecord::Compiler.build_native(**options, out: $stderr)
    end

    cli_args =
      if (sep = ARGV.index("--"))
        ARGV[(sep + 1)..]
      else
        []
      end

    status = InstantRecord::Mcp::Cli.run(
      cli_args,
      defaults: {
        root: Rails.root.to_s,
        endpoint: default_endpoint,
        models: models,
        screens: screens,
        builder: builder
      }
    )
    exit(status)
  end

  desc "Verify the compiler toolchain configuration and static AOT/32-bit compatibility (optional target: wasm, native, iphonesimulator, iphoneos)"
  task :doctor, [:target] => :environment do |_task, args|
    require "instant_record/compiler"
    toolchain = toolchain_path.call
    require_toolchain.call(toolchain)
    report = InstantRecord::Compiler.doctor(
      toolchain: toolchain,
      target: args[:target] || :wasm,
      web_dir: Rails.root.join("tmp/instant_record/compiled/web"),
      app_root: Rails.root
    )
    puts report
    abort "Doctor check failed." unless report.ok?
  end

  namespace :files do
    desc "Remove uploads of sync_file records that were given up: partials no piece has reached for DAYS days (default 2)"
    task sweep: :environment do
      days = ENV.fetch("DAYS", 2).to_f
      removed = InstantRecord::Files.store.sweep(before: days.days.ago)
      puts "Removed #{removed} given-up #{"upload".pluralize(removed)}"
    end
  end
end

Rake::Task.define_task("assets:precompile").enhance do
  case Rails.application.config.instant_record.build_on_precompile
  when true, :compiled
    Rake::Task["instant_record:compile"].invoke
    InstantRecord::Compiler.publish(Rails.root)
  when false, nil
    # The host app manages its own build.
  else
    raise ArgumentError, "build_on_precompile must be false, true, or :compiled"
  end
end
