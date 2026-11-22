require_relative "lib/instant_record/version"

Gem::Specification.new do |spec|
  spec.name        = "instant_record"
  spec.version     = InstantRecord::VERSION
  spec.authors     = ["Kieran Klaassen"]
  spec.email       = ["kieranklaassen@gmail.com"]

  spec.summary     = "Rails models that run in the browser, sync to your server, and keep working offline"
  spec.description = "Compile Rails apps to WebAssembly with Roundhouse and Spinel. Records persist in local SQLite and sync to Rails through a durable outbox."
  spec.homepage    = "https://github.com/kieranklaassen/instant_record"
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 3.3"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.bindir      = "exe"
  spec.executables = ["instant_record_mcp"]

  # db/ is not optional: the engine appends its own db/migrate to the host app's
  # migration paths, and those migrations create the tables the sync protocol
  # runs on (changes, outbox, sync_metadata, applied_mutations). Omit them and
  # the gem installs into an app that can never build its own schema.
  files = Dir[
    "{app,config,db,exe,lib,sig}/**/*",
    "frontend/**/*.js",
    "frontend/package.json",
    "CHANGELOG.md",
    "LICENSE.txt",
    "README.md",
    "compiled/pipeline/**/*.{rb,erb,c,h}",
    "compiled/web/src/**/*.js",
    "compiled/web/{index.html,vite.config.js,package.json,package-lock.json}",
    "compiled/README.md",
    "compiled/toolchain.env.example",
    "native/ios/README.md",
    "native/ios/InstantRecordNative/Package.swift",
    "native/ios/InstantRecordNative/Sources/**/*.swift"
  ]

  spec.files = files.uniq.reject do |path|
    File.directory?(path) ||
      path.start_with?("compiled/pipeline/demo/", "frontend/test/") ||
      path.end_with?(".test.js")
  end

  spec.add_dependency "rails", "~> 8.0"
  spec.add_dependency "sqlite3", "~> 2.1"
  spec.add_dependency "prism", "~> 1.0"
end
