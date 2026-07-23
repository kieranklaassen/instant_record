# Post-process the packed app.wasm with binaryen's wasm-opt: stripping debug
# and name sections shrinks the bundle ~23% (80MB -> 61.7MB). Strip-only, no
# -O passes: -O1 saved only a further 0.3% while quadrupling the pass time,
# and rewriting code risks disturbing ruby.wasm's asyncify instrumentation.
# Skipped silently when binaryen isn't installed.
WASM_OPT_FLAGS = %w[
  --strip-debug --strip-producers
  --enable-bulk-memory --enable-sign-ext --enable-mutable-globals
  --enable-nontrapping-float-to-int --enable-exception-handling
  --enable-reference-types
].freeze

namespace :instant_record do
  task :optimize_wasm do
    next if ENV["INSTANT_RECORD_SKIP_WASM_OPT"]
    next unless system("which wasm-opt > /dev/null 2>&1")

    output = Wasmify::Rails.config.output_dir
    wasm = File.join(output, "app.wasm")
    next unless File.exist?(wasm)

    optimized = "#{wasm}.opt"
    if system("wasm-opt", *WASM_OPT_FLAGS, wasm, "-o", optimized)
      before = File.size(wasm)
      FileUtils.mv(optimized, wasm)
      puts "wasm-opt: #{(before / 1e6).round(1)}MB -> #{(File.size(wasm) / 1e6).round(1)}MB"
    else
      FileUtils.rm_f(optimized)
      warn "wasm-opt failed; keeping unoptimized app.wasm"
    end
  end
end

Rake::Task["wasmify:pack"].enhance do
  Rake::Task["instant_record:optimize_wasm"].invoke
end

# Rails' ActionDispatch::Static serves the browser runtime from public/ when
# the service worker is registered on :3000 (public/index.html). Keep those
# copies in lockstep with the packed/Vite outputs — a missing pglite.data
# asset returns a 9-byte "Not Found" body and PGlite throws
# "Invalid FS bundle size: 9 !== …".
Rake::Task["instant_record:stamp_sw"].enhance do
  root = Rails.root
  wasm_src = root.join("pwa/public/app.wasm")
  wasm_dest = root.join("public/app.wasm")
  if wasm_src.file?
    FileUtils.cp(wasm_src, wasm_dest)
    puts "Synced public/app.wasm (#{(wasm_dest.size / 1e6).round(1)}MB)"
  end

  pwa_dir = root.join("pwa")
  if pwa_dir.join("package.json").file? && !ENV["INSTANT_RECORD_SKIP_PWA_BUILD"]
    puts "Building PWA (yarn build) so public/ gets rails.sw.js + pglite assets..."
    ok = system("yarn", "build", chdir: pwa_dir.to_s)
    warn "yarn build failed — public/assets may be stale" unless ok
  end

  dist = root.join("pwa/dist")
  next unless dist.directory?

  # Bundled SW + hashed PGlite wasm/data from the Vite build above.
  %w[rails.sw.js index.html boot.html favicon.ico].each do |name|
    src = dist.join(name)
    next unless src.file?

    FileUtils.cp(src, root.join("public", name))
  end

  assets_src = dist.join("assets")
  if assets_src.directory?
    assets_dest = root.join("public/assets")
    FileUtils.mkdir_p(assets_dest)
    FileUtils.rm_rf(Dir.glob(assets_dest.join("*")))
    FileUtils.cp_r(assets_src.children, assets_dest)
    data = assets_dest.glob("pglite-*.data").first
    puts "Synced public/assets from pwa/dist/assets" \
         "#{data ? " (#{File.basename(data)} #{data.size} bytes)" : ""}"
  else
    warn "pwa/dist/assets missing — PGlite cannot boot from :3000 without it"
  end
end