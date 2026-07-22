namespace :instant_record do
  desc "Build the browser bundle: compiles the Ruby wasm core (once) and packs app.wasm"
  task :build do
    require "wasmify-rails"

    # wasmify:pack precompiles assets in a subprocess; this flag stops the
    # assets:precompile enhancement below from recursing back into this task.
    ENV["INSTANT_RECORD_SKIP_BUILD"] = "1"

    core = File.join(Wasmify::Rails.config.tmp_dir, "ruby-core.wasm")
    Rake::Task["wasmify:build:core"].invoke unless File.exist?(core)
    Rake::Task["wasmify:pack"].invoke
  end
end

# Opt-in deploy hook: build the browser bundle during assets:precompile.
#
#   # config/application.rb
#   config.instant_record.build_on_precompile = true
#
# Off by default: the build needs the wasm toolchain and network access for
# ruby.wasm artifacts, which not every deploy environment has.
if Rake::Task.task_defined?("assets:precompile")
  Rake::Task["assets:precompile"].enhance do
    next if ENV["INSTANT_RECORD_SKIP_BUILD"]
    next unless Rails.application.config.instant_record.build_on_precompile

    Rake::Task["instant_record:build"].invoke
  end
end
