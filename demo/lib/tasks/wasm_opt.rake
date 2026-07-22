# Post-process the packed app.wasm with binaryen's wasm-opt: stripping debug
# sections and running -O1 shrinks the bundle ~23% (80MB -> 61MB) with no
# behavior change. Skipped silently when binaryen isn't installed.
WASM_OPT_FLAGS = %w[
  --strip-debug --strip-producers -O1
  --enable-bulk-memory --enable-sign-ext --enable-mutable-globals
  --enable-nontrapping-float-to-int --enable-exception-handling
  --enable-reference-types
].freeze

namespace :instant_record do
  task :optimize_wasm do
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