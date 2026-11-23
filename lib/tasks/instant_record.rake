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
      overrides: Rails.application.config.instant_record.include,
      shell_snapshot: Rails.application.config.instant_record.shell_snapshot
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
    output = InstantRecord::Compiler.build_native(
      **options.except(:shell_snapshot),
      target: args[:target],
      swift_out: ENV["SWIFT_OUT"],
      kotlin: ENV["KOTLIN"] == "1" || ENV["KOTLIN_OUT"].present?,
      kotlin_out: ENV["KOTLIN_OUT"],
      kotlin_package: ENV.fetch("KOTLIN_PACKAGE", "dev.instantrecord.contracts")
    )
    puts "Native libraries: #{output}"
  rescue InstantRecord::Compiler::BuildError, ArgumentError => e
    abort e.message
  end

  namespace :native do
    desc "Generate typed Swift (and optional Kotlin) contract bindings from app/screens without running a C build"
    task contracts: :environment do
      require "instant_record/compiler"
      swift_out = ENV.fetch("SWIFT_OUT") { Rails.root.join("tmp/instant_record/compiled/.build-native/generated/InstantRecordContracts.swift").to_s }
      kotlin_out = ENV["KOTLIN_OUT"] || (ENV["KOTLIN"] == "1" ? Rails.root.join("tmp/instant_record/compiled/.build-native/generated/InstantRecordContracts.kt").to_s : nil)
      result = InstantRecord::Compiler.generate_native_contracts(
        screens_dir: Rails.root.join("app/screens").to_s,
        swift_out: swift_out,
        kotlin_out: kotlin_out,
        kotlin_package: ENV.fetch("KOTLIN_PACKAGE", "dev.instantrecord.contracts")
      )
      if result[:contracts].empty?
        puts "No native contracts declared in app/screens."
      else
        result[:written].each { |lang, path| puts "Generated #{lang} contracts (#{result[:contracts].size}): #{path}" }
      end
    rescue InstantRecord::Compiler::BuildError => e
      abort e.message
    end
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

  desc "Verify the compiler toolchain, static AOT/32-bit compatibility, and schema lockfile upgrade ladder (optional target: wasm, native, iphonesimulator, iphoneos)"
  task :doctor, [:target] => :environment do |_task, args|
    require "instant_record/compiler"
    Rails.application.eager_load!
    toolchain = toolchain_path.call
    require_toolchain.call(toolchain)
    report = InstantRecord::Compiler.doctor(
      toolchain: toolchain,
      target: args[:target] || :wasm,
      web_dir: Rails.root.join("tmp/instant_record/compiled/web"),
      root: Rails.root,
      app_root: Rails.root,
      baseline: Rails.application.config.instant_record.compiled_migration_baseline,
      migration_paths: Rails.application.config.paths["db/migrate"].existent,
      models: InstantRecord.syncable_models
    )
    puts report
    abort "Doctor check failed." unless report.ok?
  end

  namespace :schema do
    desc "Generate or update db/instant_record_lock.json from db/schema.rb and db/migrate"
    task lock: :environment do
      require "instant_record/compiler"
      lock = InstantRecord::Compiler.lock_schema(
        root: Rails.root,
        baseline: Rails.application.config.instant_record.compiled_migration_baseline,
        migration_paths: Rails.application.config.paths["db/migrate"].existent
      )
      puts "Wrote #{InstantRecord::Compiler::SchemaLock.path(Rails.root)} (schema version #{lock['schema_version']}, #{lock['versions'].size} versions)"
    end

    desc "Verify db/instant_record_lock.json and replay every historical schema version + pending outbox up to HEAD"
    task verify: :environment do
      require "instant_record/compiler"
      Rails.application.eager_load!
      report = InstantRecord::Compiler.verify_schema(
        root: Rails.root,
        baseline: Rails.application.config.instant_record.compiled_migration_baseline,
        migration_paths: Rails.application.config.paths["db/migrate"].existent,
        models: InstantRecord.syncable_models
      )
      puts report
      abort "Schema lockfile verification failed." unless report.ok?
    end
  end

  desc "Replay a recorded .irtrace flight recorder file deterministically in Node AppHost"
  task :replay, [:file, :wasm] => :environment do |_task, args|
    require "instant_record/trace"

    # Support `rails instant_record:replay path/to/file.irtrace`,
    # `rails "instant_record:replay[path/to/file.irtrace]"`, and `TRACE=...`.
    extra = ARGV.drop_while { |arg| !arg.start_with?("instant_record:replay") }.drop(1)
    positional = []
    wasm_opt = args[:wasm].to_s.empty? ? ENV["WASM"] : args[:wasm]
    db_opt = ENV["DB"]
    json_opt = ENV["JSON"] == "1"
    allow_mismatch = ENV["ALLOW_DIGEST_MISMATCH"] == "1"
    stop_on_fault = ENV["STOP_ON_FAULT"] == "1"
    max_steps = ENV["MAX_STEPS"]

    i = 0
    while i < extra.length
      arg = extra[i]
      if arg == "--wasm" && extra[i + 1]
        wasm_opt = extra[i + 1]
        i += 2
      elsif arg == "--db" && extra[i + 1]
        db_opt = extra[i + 1]
        i += 2
      elsif arg == "--max-steps" && extra[i + 1]
        max_steps = extra[i + 1]
        i += 2
      elsif arg == "--json"
        json_opt = true
        i += 1
      elsif arg == "--allow-digest-mismatch"
        allow_mismatch = true
        i += 1
      elsif arg == "--stop-on-fault"
        stop_on_fault = true
        i += 1
      elsif !arg.start_with?("-")
        positional << arg
        i += 1
      else
        i += 1
      end
    end

    extra.each { |arg| Rake::Task.define_task(arg.to_sym) {} unless Rake::Task.task_defined?(arg) }

    trace_file = args[:file].to_s.empty? ? (positional[0] || ENV["TRACE"]) : args[:file]
    if trace_file.nil? || trace_file.empty?
      abort "Usage: bin/rails instant_record:replay <file.irtrace> [--wasm <app.wasm>] [--db <file.sqlite3>] [--json]"
    end

    wasm_opt ||= positional[1]
    result = InstantRecord::Trace.replay(
      trace_path: trace_file,
      wasm_path: wasm_opt,
      db_path: db_opt,
      root: defined?(Rails) && Rails.respond_to?(:root) ? Rails.root : nil,
      toolchain: defined?(Rails) && Rails.respond_to?(:root) ? toolchain_path.call : nil,
      json: json_opt,
      allow_digest_mismatch: allow_mismatch,
      stop_on_fault: stop_on_fault,
      max_steps: max_steps
    )
    puts result.stdout unless result.stdout.empty?
    warn result.stderr unless result.stderr.empty?
    abort "Replay failed (exit #{result.status})" unless result.ok?
  rescue InstantRecord::Trace::Error => e
    abort e.message
  end

  namespace :files do
    desc "Remove uploads of sync_file records that were given up: partials no piece has reached for DAYS days (default 2)"
    task sweep: :environment do
      days = ENV.fetch("DAYS", 2).to_f
      removed = InstantRecord::Files.store.sweep(before: days.days.ago)
      puts "Removed #{removed} given-up #{"upload".pluralize(removed)}"
    end
  end

  desc "Run headless dual-runtime parity checks across CRuby+DB, compiled app.wasm (Node AppHost), and Native C ABI (Fiddle)"
  task verify_parity: :environment do
    require "instant_record/testing"
    Rails.application.eager_load!
    InstantRecord::Testing.verify_parity(
      rails_app: Rails.application,
      root: Rails.root
    )
  rescue InstantRecord::Testing::Error => e
    abort e.message
  end

  desc "Run deterministic seeded multi-client chaos simulation across CRuby+DB, compiled app.wasm, and Native C ABI (SEED=, SEEDS=, STEPS=, CLIENTS=, RUNTIMES=, REQUIRE_COMPILED=1)"
  task chaos: :environment do
    require "instant_record/testing"
    Rails.application.eager_load!
    InstantRecord::Testing.run_chaos(
      rails_app: Rails.application,
      root: Rails.root
    )
  rescue InstantRecord::Testing::Error => e
    abort e.message
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
