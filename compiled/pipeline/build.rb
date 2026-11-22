#!/usr/bin/env ruby
# Build the compiled browser demo into compiled/web/dist.
#
#   ruby compiled/pipeline/build.rb
#   SYNC_ENDPOINT=http://localhost:3000/instant_record ruby compiled/pipeline/build.rb
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "instant_record/compiler"

begin
  InstantRecord::Compiler.build_demo
rescue InstantRecord::Compiler::BuildError, ArgumentError => e
  abort e.message
end
