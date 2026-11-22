#!/usr/bin/env ruby
# Build the demo app as a native library into compiled/.build-native[/target].
#
#   ruby compiled/pipeline/build_native.rb
#   ruby compiled/pipeline/build_native.rb iphonesimulator
#   ruby compiled/pipeline/build_native.rb iphoneos
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "instant_record/compiler"

begin
  InstantRecord::Compiler.build_demo_native(target: ARGV[0])
rescue InstantRecord::Compiler::BuildError, ArgumentError => e
  abort e.message
end
