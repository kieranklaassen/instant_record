require "test_helper"
require "instant_record/compiler"
require "tmpdir"

class HostAdaptersTest < ActiveSupport::TestCase
  GEM_ROOT = File.expand_path("..", __dir__)
  HostAdapters = InstantRecord::Compiler::HostAdapters
  BuildError = InstantRecord::Compiler::BuildError

  SYNC_ACTIONS = "lib/instant_record/sync_actions.rb"
  GEM_ENTRY = "lib/instant_record.rb"
  CHANNELS = "app/controllers/slack/channels_controller.rb"

  STUB = <<~'RUBY'
    def server_frame = nil
    def enforcing_server_mutator? = false
    def server_authorize_create!(_record) = nil
    def server_finalize_create!(_record) = nil
    def server_authorize_update_before!(_record) = nil
    def server_finalize_update!(_record) = nil
    def server_authorize_destroy!(_record) = nil
    def server_finalize_destroy!(_record) = nil
    def server_note_read(_record) = nil
    def execute_on_server(_name, _args, _mutation_id) = nil
    def register(_klass, _action_name, _block = nil) = nil

    def dispatch(name, _args)
      raise ArgumentError, "Unknown sync_action: " + name
    end
  RUBY

  INDENTED_STUB = STUB.gsub(/^(?=.)/, "  ")

  test "sync_actions loses its server code and takes plain hash arguments" do
    adapted = install(SYNC_ACTIONS, <<~'RUBY')
      # é comment
      module SyncActions
        def perform_sync_action(action_name, args = nil, mutation_id: nil, **kwargs)
          other(args)
        end

        # frame — comment stays
        class ServerFrame # ☕
          def registry = 1
          def mutate(name, **kwargs) = 1
        end

        def mutate( mutator_name ,
                    **kwargs )
          merged  =  args.merge(kwargs) # gone
          normalized   =  normalize_args(merged) # ☕ kept
          kept(normalized)
        end

        def server_frame
          def resolve = 1
        end
        # between
        def registry = {}
        module ActiveJobCommitGuard
          def dispatch = 1
        end
        def kept(value) = value
      end
    RUBY

    assert_equal <<~'RUBY'.sub("STUB\n") { INDENTED_STUB }, adapted
      # é comment
      module SyncActions
        def perform_sync_action(action_name, args = {}, mutation_id: nil)
          InstantRecord::SyncActions.mutate("#{name}.#{action_name}", args, mutation_id: mutation_id)
        end

        # frame — comment stays

        def mutate(mutator_name, args = {}, mutation_id: nil)
          normalized = normalize_args(args) # ☕ kept
          kept(normalized)
        end

      STUB
        # between
        def kept(value) = value
      end
    RUBY
  end

  test "sync_actions strips every CRuby-only method and stubs only the first" do
    %i[
      server_frame enforcing_server_mutator?
      server_authorize_create! server_finalize_create!
      server_authorize_update_before! server_finalize_update!
      server_authorize_destroy! server_finalize_destroy!
      server_note_read with_server_frame execute_on_server
      registry reset_registry! register resolve dispatch
      defer_active_job? install_active_job_guard! invoke_callable
    ].each do |name|
      assert_equal "a\n#{STUB}b\n", install(SYNC_ACTIONS, "a\ndef #{name}\nend\nb\n"), name.to_s
      assert_equal "#{STUB}b\n", install(SYNC_ACTIONS, "def registry = 1\ndef #{name} = 2\nb\n"), name.to_s
    end
    assert_equal STUB, install(SYNC_ACTIONS, "def self.registry = 1\n")
  end

  test "sync_actions rewrites each match when a pattern appears twice" do
    source = <<~RUBY
      class ServerFrame; end
      module ActiveJobCommitGuard; end
      def mutate(name, **kwargs)
        merged = 1
        merged = 2
        normalized = 1
        normalized = 2
      end
    RUBY
    adapted = <<~RUBY
      def mutate(mutator_name, args = {}, mutation_id: nil)
        normalized = normalize_args(args)
        normalized = normalize_args(args)
      end
    RUBY

    assert_equal adapted * 2, install(SYNC_ACTIONS, source * 2)
  end

  test "sync_actions leaves code that only resembles a pattern alone" do
    [
      "class Frames::ServerFrame\nend\n",
      "class ::ServerFrame\nend\n",
      "class OtherFrame\nend\n",
      "module ServerFrame\nend\n",
      "class ActiveJobCommitGuard\nend\n",
      "module OtherGuard\nend\n",
      "module A::ActiveJobCommitGuard\nend\n",
      "def perform_sync_action(name, args = {})\nend\n",
      "def perform_sync_action\nend\n",
      "def mutate(name, args: 1)\n  merged = 1\nend\n",
      "def mutate\n  normalized = 1\nend\n",
      "def other(**kwargs)\n  merged = 1\nend\n",
      "# class ServerFrame\nX = 'def registry'\n",
      ""
    ].each { |source| assert_equal source, install(SYNC_ACTIONS, source) }
  end

  test "sync_actions still adapts methods nested in an untouched method" do
    assert_equal "def mutate(name)\n#{INDENTED_STUB}end\n",
      install(SYNC_ACTIONS, "def mutate(name)\n  def registry = 1\nend\n")
  end

  test "sync_actions rewrites only the top level of a mutate body" do
    signature = "def mutate(mutator_name, args = {}, mutation_id: nil)"
    {
      "def mutate(n, **k)\nend\n" => "#{signature}\nend\n",
      "def mutate n, **k\n  other = 1\nend\n" => "#{signature}\n  other = 1\nend\n",
      "def mutate(n, **k)\n  merged ||= 1\n  if a\n    merged = 1\n    normalized = 2\n  end\n  def registry = 1\nend\n" =>
        "#{signature}\n  merged ||= 1\n  if a\n    merged = 1\n    normalized = 2\n  end\n  def registry = 1\nend\n",
      "def mutate(n, **k)\n  merged =\n    1\n  normalized =\n    2\nend\n" =>
        "#{signature}\n  normalized = normalize_args(args)\nend\n"
    }.each { |source, expected| assert_equal expected, install(SYNC_ACTIONS, source) }
  end

  test "sync_actions replaces a whole perform_sync_action at its own indent" do
    assert_equal <<~'RUBY'.gsub("TAB", "\t"), install(SYNC_ACTIONS, "\tdef self.perform_sync_action a, **k\n\t\tdef registry = 1\n\tend # kept\n")
      TABdef perform_sync_action(action_name, args = {}, mutation_id: nil)
      TAB  InstantRecord::SyncActions.mutate("#{name}.#{action_name}", args, mutation_id: mutation_id)
      TABend # kept
    RUBY
  end

  test "sync_actions reports source it cannot adapt" do
    {
      "def (" => "Cannot parse lib/instant_record/sync_actions.rb",
      "module A; def registry = 1\nend\n" => "Invalid Ruby after adapting sync_actions.rb",
      "def registry = 1; def resolve = 2\n" => "Overlapping AST edits at byte offset 0 < 34"
    }.each do |source, message|
      error = assert_raises(BuildError) { install(SYNC_ACTIONS, source) }
      assert_equal message, error.message
    end
  end

  test "InstantRecord.mutate takes a plain hash in every definition" do
    assert_equal "def mutate(mutator_name, args = {}, mutation_id: nil)\n  SyncActions.mutate(mutator_name, args, mutation_id: mutation_id)\nend\n",
      install(GEM_ENTRY, "def mutate(**kwargs) = 1\n")
    assert_equal <<~RUBY, install(GEM_ENTRY, "def mutate(name, **kwargs)\nend\n\ndef other(**kwargs) = 1\nclass A\n  def self.mutate name, **kwargs\n  end # é\nend\n")
      def mutate(mutator_name, args = {}, mutation_id: nil)
        SyncActions.mutate(mutator_name, args, mutation_id: mutation_id)
      end

      def other(**kwargs) = 1
      class A
        def mutate(mutator_name, args = {}, mutation_id: nil)
          SyncActions.mutate(mutator_name, args, mutation_id: mutation_id)
        end # é
      end
    RUBY

    ["def mutate(name)\nend\n", "def mutate\nend\n", "def mutate(**k)\nend\ndef (", ""].each do |source|
      assert_equal source, install(GEM_ENTRY, source)
    end
  end

  test "a mutate nested in a rewritten InstantRecord.mutate overlaps" do
    error = assert_raises(BuildError) { install(GEM_ENTRY, "def mutate(**k)\n  def mutate(**j) = 1\nend\n") }
    assert_equal "Overlapping AST edits at byte offset 18 < 41", error.message
  end

  test "install succeeds when the rewritten files are missing" do
    Dir.mktmpdir do |app|
      FileUtils.mkdir_p(File.join(app, "lib/instant_record"))
      HostAdapters::Wasm.install(gem_src: GEM_ROOT, app_dir: app)

      refute File.exist?(File.join(app, SYNC_ACTIONS))
      refute File.exist?(File.join(app, GEM_ENTRY))
    end
  end

  test "thread replies become an array in every matching ternary" do
    assert_equal "r = @thread_parent ? a.b(1).to_a : []\ns = @thread_parent   ?\n  'é☕'.c.to_a\n  : [ ]\n",
      coerce("r = @thread_parent ? a.b(1) : []\ns = @thread_parent   ?\n  'é☕'.c\n  : [ ]\n")
    assert_equal "@thread_parent ? f(@thread_parent ? a.to_a : []).to_a : []\n",
      coerce("@thread_parent ? f(@thread_parent ? a : []) : []\n")
  end

  test "only a @thread_parent ternary between a call and an empty array is coerced" do
    [
      "@thread_parent ? a.to_a : []",
      "@thread_parent ? a.b : [1]",
      "@thread_parent ? a.b : nil",
      "@thread_parent ? a.b : {}",
      "@thread_parent ? a.b : ([])",
      "@thread_parent ? @replies : []",
      "@thread_parent ? (a.b) : []",
      "@thread_parent ? () : ()",
      "@other ? a.b : []",
      "thread_parent ? a.b : []",
      "(@thread_parent) ? a.b : []",
      "if @thread_parent then a.b else [] end",
      "a.b if @thread_parent",
      "other"
    ].each do |source|
      error = assert_raises(BuildError, source) { coerce(source) }
      assert_equal "demo seam did not apply: #{CHANNELS}: @thread_parent ternary not found", error.message

      hit = "x = @thread_parent ? a.b"
      assert_equal "#{source}\n#{hit}.to_a : []\n", coerce("#{source}\n#{hit} : []\n")
    end
  end

  test "thread replies need a controller that parses, if there is one" do
    error = assert_raises(BuildError) { coerce("def (") }
    assert_equal "Cannot parse #{CHANNELS}", error.message

    Dir.mktmpdir do |app|
      HostAdapters::Demo.apply(app_dir: app)
      assert_empty Dir.children(app)
    end
  end

  private

  def install(path, source)
    rewrite(path, source) { |app| HostAdapters::Wasm.install(gem_src: GEM_ROOT, app_dir: app) }
  end

  def coerce(source)
    rewrite(CHANNELS, source) { |app| HostAdapters::Demo.apply(app_dir: app) }
  end

  def rewrite(path, source)
    Dir.mktmpdir do |app|
      FileUtils.mkdir_p(File.join(app, "lib/instant_record"))
      file = File.join(app, path)
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, source)
      yield app
      File.read(file, encoding: Encoding::UTF_8)
    end
  end
end
