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
    {
      root: Rails.root,
      models: InstantRecord.syncable_models.map(&:name),
      toolchain: toolchain_path.call,
      endpoint: ENV.fetch("SYNC_ENDPOINT") { Rails.application.config.instant_record.mount_path || InstantRecord::DEFAULT_MOUNT_PATH },
      baseline: Rails.application.config.instant_record.compiled_migration_baseline,
      migration_paths: Rails.application.config.paths["db/migrate"].existent
    }
  end

  desc "Compile this Rails app to a static browser site using Roundhouse, Spinel and SQLite"
  task compile: :environment do
    # The options first: asking for them is what loads the compiler.
    options = compiler_options.call
    output = InstantRecord::Compiler.build(**options)
    puts "Compiled browser site: #{output}"
  end

  desc "Build the compiled browser site"
  task build: :compile

  desc "Build this Rails app, with its app/screens, as libraries a native app links: instant_record:native[iphonesimulator] or [iphoneos]"
  task :native, [:target] => :environment do |_task, args|
    options = compiler_options.call
    require_toolchain.call(options[:toolchain])
    output = InstantRecord::Compiler.build_native(**options, target: args[:target])
    puts "Native libraries: #{output}"
  rescue ArgumentError => e
    abort e.message
  end

  desc "Verify the compiler toolchain configuration (optional target: wasm, native, iphonesimulator, iphoneos)"
  task :doctor, [:target] => :environment do |_task, args|
    require "instant_record/compiler"
    toolchain = toolchain_path.call
    require_toolchain.call(toolchain)
    report = InstantRecord::Compiler.doctor(
      toolchain: toolchain,
      target: args[:target] || :wasm,
      web_dir: Rails.root.join("tmp/instant_record/compiled/web")
    )
    puts report
    abort "Toolchain check failed." unless report.ok?
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
