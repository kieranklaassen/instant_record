require_relative "lib/instant_record/version"

Gem::Specification.new do |spec|
  spec.name        = "instant_record"
  spec.version     = InstantRecord::VERSION
  spec.authors     = ["Kieran Klaassen"]
  spec.email       = ["kieranklaassen@gmail.com"]

  spec.summary     = "Rails models that run in the browser, sync to your server, and keep working offline"
  spec.description = "InstantRecord boots real Active Record inside the browser with ruby.wasm and wasmify-rails, persists to PGlite, and writes optimistically through a durable outbox that syncs to a Rails + Postgres server."
  spec.homepage    = "https://github.com/kieranklaassen/instant_record"
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 3.3"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  # db/ is not optional: the engine appends its own db/migrate to the host app's
  # migration paths, and those migrations create the tables the sync protocol
  # runs on (changes, outbox, sync_metadata, applied_mutations). Omit them and
  # the gem installs into an app that can never build its own schema.
  spec.files = Dir["{app,config,db,lib}/**/*", "CHANGELOG.md", "LICENSE.txt", "README.md"]

  spec.add_dependency "rails", ">= 8.0"
  spec.add_dependency "wasmify-rails", "~> 0.5"
end
