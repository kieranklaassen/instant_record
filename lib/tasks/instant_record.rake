namespace :instant_record do
  # What both builds are told about this app.
  compiler_options = lambda do
    require "instant_record/compiler"
    Rails.application.eager_load!
    {
      root: Rails.root,
      models: InstantRecord.syncable_models.map(&:name),
      toolchain: ENV.fetch("INSTANT_RECORD_TOOLCHAIN") { Rails.root.join("config/instant_record_toolchain.env") },
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
    abort "No toolchain file at #{options[:toolchain]}. Run bin/rails generate instant_record:install, or set INSTANT_RECORD_TOOLCHAIN." unless File.file?(options[:toolchain])
    abort "Unknown target #{args[:target]}. Leave it out for this machine, or use iphonesimulator or iphoneos." unless [nil, "iphonesimulator", "iphoneos"].include?(args[:target])
    output = InstantRecord::Compiler.build_native(**options, target: args[:target])
    puts "Native libraries: #{output}"
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
