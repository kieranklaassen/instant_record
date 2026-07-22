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