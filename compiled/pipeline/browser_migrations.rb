# Compatibility shim: InstantRecord::Compiler::BrowserMigrations lives in
# lib/instant_record/compiler/browser_migrations.rb.
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__)) unless $LOAD_PATH.include?(File.expand_path("../../lib", __dir__))
require "instant_record/compiler/browser_migrations"

BrowserMigrations = InstantRecord::Compiler::BrowserMigrations unless defined?(::BrowserMigrations)

if $PROGRAM_NAME == __FILE__
  root, output = ARGV
  migration_paths = ENV["INSTANT_RECORD_MIGRATION_PATHS"]&.then { |raw| JSON.parse(raw) }
  plan = InstantRecord::Compiler::BrowserMigrations.plan(
    root: root,
    baseline: ENV["INSTANT_RECORD_MIGRATION_BASELINE"],
    migration_paths: migration_paths
  )
  File.write(output, JSON.generate(plan))
end
