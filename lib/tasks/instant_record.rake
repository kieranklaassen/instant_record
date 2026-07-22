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
    Rake::Task["instant_record:stamp_sw"].invoke
  end

  # Stamp the app.wasm digest into the service worker so its bytes change on
  # every rebuild. The browser's update check then installs the new worker,
  # which claims open tabs and reloads them onto the new bundle — without
  # this, installed clients keep running the old VM indefinitely.
  desc "Stamp the current app.wasm digest into pwa/rails.sw.js"
  task :stamp_sw do
    require "digest"

    root = defined?(Rails) && Rails.respond_to?(:root) && Rails.root ? Rails.root : Pathname.new(Dir.pwd)
    sw = root.join("pwa/rails.sw.js")
    wasm = root.join("pwa/public/app.wasm")
    next unless File.exist?(sw) && File.exist?(wasm)

    version = Digest::SHA256.file(wasm).hexdigest[0, 12]
    contents = File.read(sw)
    stamped = contents
      .sub(/__INSTANT_RECORD_BUILD_VERSION__/, version)
      .gsub(/const BUILD_VERSION = "[0-9a-f]{12}";/, %(const BUILD_VERSION = "#{version}";))
    File.write(sw, stamped)
    puts "Stamped service worker build version: #{version}"
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
