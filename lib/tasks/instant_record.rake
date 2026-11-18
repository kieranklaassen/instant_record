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

  desc "Build the compiled browser site"
  task build: :compile
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
