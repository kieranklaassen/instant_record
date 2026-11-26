require "test_helper"
require "instant_record/compiler"
require "digest"
require "fileutils"
require "tmpdir"

class EntryBuilderTest < ActiveSupport::TestCase
  EntryBuilder = InstantRecord::Compiler::EntryBuilder
  BuildError = InstantRecord::Compiler::BuildError
  Manifest = InstantRecord::Compiler::Manifest

  MAIN = %(require_relative "boot"\nif ARGV.length > 0 && ARGV[0] == "sidekiq"\nend\n)
  PLAN = { "version" => 3, "migrations" => { "10" => ["SELECT 10"], "9" => [], "11" => ["SELECT 11"] } }.freeze

  # Digests of whole entries: an edit to a template changes them on purpose, a
  # refactoring must not. The other tests here hold the parts that vary as text.
  test "whole entries keep their bytes" do
    in_app do |emit, app|
      write(app, "app/models/issue.rb", "class Issue\n  sync_action :close\nend\n")
      write(app, "app/screens/inbox_screen.rb", "")
      rendered = %w[full demo].to_h do |kind|
        demo = kind == "demo"
        given = demo ? { models: ["Note"], demo: true } : {
          manifest: { "mode" => "app", "models" => [{ "name" => "Task", "sync_scope" => { "column" => "team_id" } }] },
          sync_windows: { "Task" => { limit: 5, partition_by: "room_id" } },
          endpoint: "https://api.example.test", mount_path: "/sync", shell_fingerprint: "abc"
        }
        wasm(emit, app_dir: app, **given)
        screens = native(emit, app, **given)
        assert_equal ["inbox"], screens
        [kind, %w[wasm native].map { |target| Digest::SHA256.hexdigest(read(emit, "main_#{target}.rb"))[0, 16] }]
      end

      assert_equal({ "full" => %w[ae2c5d0c80998933 3971549a1f5cc560], "demo" => %w[e8d4136ee4600eea ea2468610e3c2a85] }, rendered)
      assert_equal "class Release; end\n", read(emit, "app/models/release.rb")
    end
  end

  test "without screens or sync actions the native entry refuses every name" do
    in_app do |emit, app|
      wasm(emit)
      assert_equal [], native(emit, app)

      entry = read(emit, "main_native.rb")
      assert_includes entry, <<~ACTIONS

        module InstantRecord
          module SyncActions
            def self.dispatch(name, _args)
              raise ArgumentError, "Unknown sync_action: " + name
            end
          end
        end
      ACTIONS
      assert_includes entry, <<~SCREENS

        module NativeScreens
          def self.find(name, _params)
            raise ArgumentError, "No screen named " + name
          end
        end
      SCREENS
    end
  end

  test "the native entry finds each screen by name" do
    in_app do |emit, app|
      %w[inbox archive].each { |name| write(app, "app/screens/#{name}_screen.rb", "") }
      wasm(emit)
      assert_equal %w[archive inbox], native(emit, app)
      assert_includes read(emit, "main_native.rb"), <<-CASES
    case name
    when "archive" then ArchiveScreen.new(params)
    when "inbox" then InboxScreen.new(params)
    else raise ArgumentError, "No screen named " + name
      CASES
    end
  end

  test "migrations run in version order, skip empty transactions and stamp the latest version" do
    assert_equal "", EntryBuilder.migrations(demo: true, plan: PLAN, previous: "before")
    assert_equal <<~STEPS, EntryBuilder.migrations(demo: false, plan: PLAN, previous: "before", applied: 'stamp("<<version>>")')

      if restored
        previous = before
        if previous < "00000000000000000009"
          stamp("00000000000000000009")
        end
        if previous < "00000000000000000010"
          Db.exec("BEGIN IMMEDIATE")
          begin
            Db.exec("SELECT 10")
            Db.exec("COMMIT")
          rescue StandardError
            begin
              Db.exec("ROLLBACK")
            rescue StandardError
            end
            raise
          end
          stamp("00000000000000000010")
        end
        if previous < "00000000000000000011"
          Db.exec("BEGIN IMMEDIATE")
          begin
            Db.exec("SELECT 11")
            Db.exec("COMMIT")
          rescue StandardError
            begin
              Db.exec("ROLLBACK")
            rescue StandardError
            end
            raise
          end
          stamp("00000000000000000011")
        end
      end
      stamp("00000000000000000011")
    STEPS
  end

  test "models come from the manifest, then from the list" do
    task = { "models" => [{ "name" => "Task" }] }
    assert_equal ["Task"], EntryBuilder.app_models(manifest: task, models: ["Note"])
    assert_equal ["Note"], EntryBuilder.app_models(manifest: { "models" => [] }, models: ["Note"])
    Dir.mktmpdir do |dir|
      write(dir, "manifest.json", JSON.generate(task))
      path = File.join(dir, "manifest.json")
      [path, Pathname(path)].each { |given| assert_equal ["Task"], EntryBuilder.app_models(manifest: given) }
    end

    nameless = "Declare at least one named model that includes InstantRecord::Syncable."
    assert_refused(nameless) { EntryBuilder.app_models(manifest: { "mode" => "island" }, models: ["Note"]) }
    [nil, [], ["note"], [:Note]].each { |models| assert_refused(nameless) { EntryBuilder.app_models(models: models) } }
    error = assert_raises(ArgumentError) { EntryBuilder.app_models(manifest: 42) }
    assert_equal "Unsupported manifest: 42", error.message
  end

  test "sync windows and scopes are sorted, skipped when blank and refused when not identifiers" do
    models = [
      { "name" => "Task", "sync_scope" => { "column" => "team_id" }, "sync_window" => { "limit" => 2 } },
      { "name" => "lower", "sync_scope" => { "column" => "x" } },
      { "name" => "Blank", "sync_scope" => { "column" => "" } }
    ]
    assert_equal "Task.sync_window(limit: 2)\n", EntryBuilder.sync_windows_code(manifest: Manifest.new("models" => models))
    assert_equal "Task.sync_scope(:team_id)\n", EntryBuilder.sync_scopes_code(manifest: { "models" => models })
    assert_equal "", EntryBuilder.sync_windows_code(manifest: { "models" => models }, sync_windows: {})
    assert_equal "", EntryBuilder.sync_windows_code
    assert_equal "", EntryBuilder.sync_scopes_code(manifest: nil)
    assert_equal "A.sync_window(limit: 1)\nB.sync_window(limit: 2, partition_by: :day)\n",
      EntryBuilder.sync_windows_code(sync_windows: { B: { "limit" => 2, "partition_by" => :day }, A: { limit: 1, partition_by: "" } })

    {
      { "bad" => { limit: 1 } } => 'Invalid sync_window model name: "bad"',
      { "A" => { limit: 0 } } => "Invalid sync_window limit for A: 0",
      { "A" => { limit: "1" } } => 'Invalid sync_window limit for A: "1"',
      { "A" => { limit: 1, partition_by: "a b" } } => 'Invalid sync_window partition_by column for A: "a b"'
    }.each { |windows, message| assert_refused(message) { EntryBuilder.sync_windows_code(sync_windows: windows) } }
    assert_refused('Invalid sync_scope column "a b" on A') do
      EntryBuilder.sync_scopes_code(manifest: { "models" => [{ "name" => "A", "sync_scope" => { "column" => "a b" } }] })
    end
  end

  test "each shape of sync action gets its own call" do
    {
      nil => "(args)", "" => "", "()" => "", "(&block)" => "",
      "(a)" => "(args)", "(a = 1)" => "(args)", "(*rest)" => "(args)", "(**rest)" => "(args)", "(a, b:)" => "(args)", "(a:, **rest)" => "(args)",
      "(a:)" => '(a: args["a"])', "(*rest, a:)" => '(a: args["a"])', "(a: other)" => '(a: args["a"])',
      "(a: nil)" => '(a: args.key?("a") ? args["a"] : nil)',
      "(a: true, b: false)" => '(a: args.key?("a") ? args["a"] : true, b: args.key?("b") ? args["b"] : false)',
      "(a: -1, b: 1.5)" => '(a: args.key?("a") ? args["a"] : -1, b: args.key?("b") ? args["b"] : 1.5)',
      "(a: 'q\"', b: :sym)" => '(a: args.key?("a") ? args["a"] : "q\"", b: args.key?("b") ? args["b"] : :sym)'
    }.each do |parameters, call|
      source = "class A\n  sync_action :go\n#{"  def self.go#{parameters}; end\n" if parameters}end\n"
      assert_equal [["A.go", "A.go#{call}"]], actions(source), "def self.go#{parameters}"
    end
  end

  test "sync actions are found once each, sorted, wherever the class is nested" do
    source = <<~RUBY
      module Billing
        class ::Top::Invoice
          sync_action :pay
          sync_action "pay"
          sync_action :credit
          self.sync_action :ignored
          class << Other; def pay(a:); end; end
          class Line; sync_action :drop; end
        end
      end
      class some::Thing; sync_action :run; end
      sync_action :outside
    RUBY
    assert_equal [
      ["Billing::Top::Invoice.credit", "Billing::Top::Invoice.credit(args)"],
      ["Billing::Top::Invoice.pay", "Billing::Top::Invoice.pay(args)"],
      ["Billing::Top::Invoice::Line.drop", "Billing::Top::Invoice::Line.drop(args)"]
    ], actions(source)
    assert_equal [], EntryBuilder.discover_sync_actions(nil)
    assert_equal [], EntryBuilder.discover_sync_actions("/no/such/app")
  end

  test "only the class's own methods shape a call" do
    source = <<~RUBY
      class A
        sync_action :go
        def self.go(a:); end
        def go; end
        def other.go(b:); end
        class << self; end
      end
      class Empty; end
    RUBY
    assert_equal [["A.go", 'A.go(a: args["a"])']], actions(source)
  end

  test "a sync action that cannot be compiled is refused with its line" do
    {
      "sync_action" => "requires a literal symbol or string name.", "sync_action name" => "requires a literal symbol or string name.",
      "sync_action :Close" => 'Invalid sync_action name "Close".', "sync_action :a=" => 'Invalid sync_action name "a=".',
      "sync_action(:go) { 1 }" => "sync_action :go cannot use a block in compiled builds; define def self.go(args) instead.",
      "sync_action(:Go) { 1 }" => 'Invalid sync_action name "Go".'
    }.each do |line, message|
      error = assert_raises(BuildError, line) { actions("class A\n  #{line}\nend\n") }
      assert_match(/a\.rb:2: (sync_action )?#{Regexp.escape(message)}\z/, error.message)
    end
    error = assert_raises(BuildError) { actions("class {") }
    assert_match(/\ACould not parse .*a\.rb for sync_action discovery\z/, error.message)
  end

  test "an entry is refused when a file it starts from is not as expected" do
    in_app do |emit, app|
      write(emit, "main.rb", "puts 1\n")
      assert_refused("Expected sidekiq marker in #{emit}/main.rb") { wasm(emit, models: []) }

      ["none", EntryBuilder::BANNER * 2].each do |source|
        write(emit, "main_wasm.rb", source)
        assert_refused("main_wasm.rb has no entry to start from") { native(emit, app, models: []) }
      end

      write(emit, "main_wasm.rb", EntryBuilder::BANNER)
      File.delete(File.join(emit, "app/models/instant_record/host.rb"))
      assert_refused("expected emitted InstantRecord::Host adapter in #{emit}") { native(emit, app) }
      assert File.file?(File.join(emit, "main_native.rb")), "the entry is written before the adapter is looked for"

      write(app, "app/screens/Bad_screen.rb", "")
      error = assert_raises(BuildError) { native(emit, app, models: []) }
      assert_match(/in lower case with single underscores .*: Bad\z/, error.message)
    end
    assert_refused("EntryBuilder: nothing filled <<b>>") { EntryBuilder.fill("<<a>><<b>>", { "a" => "1" }) }
  end

  # Which of two faults in one app is reported differs per target: that order is kept too.
  test "the first of two faults is the one reported" do
    in_app do |emit, app|
      write(app, "app/models/a.rb", "class {")
      assert_refused(/\ADeclare at least one/) { wasm(emit, app_dir: app, models: []) }
      assert_refused(/\ACould not parse/) { wasm(emit, app_dir: app, migration_plan: {}, sync_windows: { "bad" => {} }) }

      write(emit, "main_wasm.rb", EntryBuilder::BANNER)
      unfilled = { "migrations" => { "1" => ["<<hole>>"] } }
      assert_refused("EntryBuilder: nothing filled <<hole>>") { native(emit, app, migration_plan: unfilled) }
      assert_refused(/\ACould not parse/) { wasm(emit, app_dir: app, migration_plan: unfilled) }
    end
  end

  private

  def in_app
    Dir.mktmpdir do |dir|
      emit, app = File.join(dir, "emit"), File.join(dir, "app")
      FileUtils.mkdir_p(app)
      write(emit, "main.rb", MAIN)
      write(emit, "app/models/instant_record/host.rb", "")
      write(dir, "pipeline/sqlite_release.rb", "class Release; end\n")
      yield emit, app
    end
  end

  def wasm(emit, **given)
    EntryBuilder.write_wasm_entry(**{ emit_dir: emit, pipeline_dir: File.join(emit, "../pipeline"), migration_plan: PLAN, models: ["Note"] }, **given)
  end

  def native(emit, app, **given)
    EntryBuilder.write_native_entry(**{ tree_dir: emit, app_dir: app, migration_plan: PLAN, models: ["Note"] }, **given)
  end

  def actions(source)
    Dir.mktmpdir do |dir|
      write(dir, "app/models/a.rb", source)
      EntryBuilder.discover_sync_actions(dir).map { |found| ["#{found[:class_name]}.#{found[:action]}", found[:call]] }
    end
  end

  def assert_refused(message, &block)
    assert_operator message, :===, assert_raises(BuildError, &block).message
  end

  def write(dir, name, text)
    path = File.join(dir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def read(dir, name) = File.read(File.join(dir, name))
end
