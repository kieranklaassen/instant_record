#!/usr/bin/env ruby
# Replace the build machine's path inside a wasm binary with a neutral one of
# the same byte length.
#
#   ruby compiled/deploy/scrub_path.rb <wasm> <local-prefix>
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "instant_record/compiler/path_scrubber"

if ARGV.length != 2
  abort "usage: scrub_path.rb <wasm> <local-prefix>"
end

result = InstantRecord::Compiler::PathScrubber.scrub(ARGV[0], ARGV[1])
puts "replaced #{result[:count]} occurrence(s); occurrences left: #{result[:remaining]}; size #{result[:size]}"
