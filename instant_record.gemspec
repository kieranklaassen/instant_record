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

  spec.files = Dir["{app,config,lib}/**/*", "CHANGELOG.md", "LICENSE.txt", "README.md"]

  spec.add_dependency "rails", ">= 8.0"
end
