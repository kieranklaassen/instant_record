require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

desc "Compile the demo app to a static browser site in compiled/web/dist"
task :compile do
  require_relative "lib/instant_record/compiler"
  InstantRecord::Compiler.build_demo
end

namespace :compile do
  desc "Compile the demo app as a native library (optional target: iphonesimulator or iphoneos)"
  task :native, [:target] do |_task, args|
    require_relative "lib/instant_record/compiler"
    InstantRecord::Compiler.build_demo_native(target: args[:target])
  end

  desc "Verify compiled/toolchain.env for a target (wasm, native, iphonesimulator, iphoneos)"
  task :doctor, [:target] do |_task, args|
    require_relative "lib/instant_record/compiler"
    report = InstantRecord::Compiler.doctor(
      toolchain: InstantRecord::Compiler.demo_toolchain,
      target: args[:target] || :wasm,
      web_dir: File.expand_path("compiled/web", __dir__)
    )
    puts report
    abort "Toolchain check failed." unless report.ok?
  end
end

task default: :test
