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

  test "only the native host's calls are declared for Roundhouse, each with its arguments" do
    Dir.mktmpdir do |dir|
      staged = %i[Wasm Native].to_h do |name|
        app = File.join(dir, name.to_s)
        FileUtils.mkdir_p(File.join(app, "lib/instant_record"))
        HostAdapters.const_get(name).install(gem_src: GEM_ROOT, app_dir: app)
        [name, File.join(app, "sig/instant_record/native_host.rbs")]
      end

      refute File.exist?(staged[:Wasm])
      declared = File.read(staged[:Native]).scan(/def self\.(\w+): \(([^)]*)\)/).to_h { |name, args| [name, args.split(", ").size] }
      bound = InstantRecord::Compiler::EntryBuilder::NATIVE_HOST.scan(/ffi_func :(\w+), \[([^\]]*)\]/).to_h { |name, args| [name, args.split(", ").size] }
      called = HostAdapters::Native.host_source.scan(/NativeHost\.(\w+)/).flatten.uniq

      assert_equal bound, declared
      assert_equal bound.keys.sort, called.sort
    end
  end

  # The native entry gets this source as it is, past Roundhouse, which lowers blank?.
  test "the native host knows an unset id without blank?" do
    host = Module.new.tap { |mod| mod.module_eval(HostAdapters::Native.host_source) }.const_get(:InstantRecord)::Host
    plain = Class.new(String) { undef_method :blank? }

    assert host.blank_id?(nil)
    assert host.blank_id?(plain.new(""))
    refute host.blank_id?(plain.new("0193"))
  end

  test "HostAdapters.for resolves built-in targets, custom adapters, and rejects unknown targets" do
    assert_same HostAdapters::Wasm, HostAdapters.for(:wasm)
    assert_same HostAdapters::Wasm, HostAdapters.for("wasm")
    assert_equal :wasm, HostAdapters::Wasm.target

    %i[native iphonesimulator iphoneos].each do |target|
      assert_same HostAdapters::Native, HostAdapters.for(target)
      assert_same HostAdapters::Native, HostAdapters.for(target.to_s)
    end
    assert_equal :native, HostAdapters::Native.target

    custom = Struct.new(:install, :host_source).new(nil, "")
    assert_same custom, HostAdapters.for(custom)

    error = assert_raises(ArgumentError) { HostAdapters.for(:android) }
    assert_equal "Unknown host adapter target: :android", error.message
  end

  test "Wasm and Native host_source share compiled host seams with target-specific channels and blank_id?" do
    wasm_src = HostAdapters::Wasm.host_source
    native_src = HostAdapters::Native.host_source

    assert_same HostAdapters::Wasm::HOST_SOURCE, wasm_src
    assert_same HostAdapters::Native::HOST_SOURCE, native_src
    assert wasm_src.frozen?
    assert native_src.frozen?
    assert Prism.parse(wasm_src).success?
    assert Prism.parse(native_src).success?

    shared_body = ->(src) { src[/module Host\n(.*?)\n    # Compiled models/m, 1] }
    wasm_shared = shared_body.call(wasm_src)
    assert_includes wasm_shared, "def with_savepoint(&block)"
    assert_equal wasm_shared, shared_body.call(native_src)

    assert_includes wasm_src, "# Compiled wasm32-wasi host adapter (see Compiler::HostAdapters::Wasm)."
    assert_includes wasm_src, "id.blank?"
    assert_includes wasm_src, 'File.read("/host/#{name}")'
    assert_includes wasm_src, 'File.write("/host/#{name}", body)'

    assert_includes native_src, "# Compiled native host adapter (see Compiler::HostAdapters::Native)."
    assert_includes native_src, "id.to_s.empty?"
    assert_includes native_src, "NativeHost.ir_host_take(name)"
    assert_includes native_src, "NativeHost.ir_host_give(name, body)"

    [wasm_src, native_src].each do |src|
      executed = []
      sandbox = Module.new do
        const_set(:Db, Module.new do
          define_singleton_method(:exec) { |sql| executed << sql }
        end)
        module_eval(src)
      end
      sandbox.const_get(:InstantRecord).const_set(:DEFAULT_MOUNT_PATH, InstantRecord::DEFAULT_MOUNT_PATH)
      host = sandbox.const_get(:InstantRecord)::Host

      assert_equal true, host.browser?
      assert_nil host.load_engine
      assert_nil host.load_inertia_renderer
      assert_nil host.load_branch_store
      assert_nil host.install_active_job_guard
      assert_nil host.resolve_syncable_model("Item")
      assert_equal [], host.discover_syncable_models
      assert_equal InstantRecord::DEFAULT_MOUNT_PATH, host.default_mount_path

      assert_equal :ok, host.with_savepoint { :ok }
      assert_equal ["SAVEPOINT ir_sp_1", "RELEASE SAVEPOINT ir_sp_1"], executed

      executed.clear
      error = assert_raises(RuntimeError) { host.with_savepoint { raise "boom" } }
      assert_equal "boom", error.message
      assert_equal ["SAVEPOINT ir_sp_2", "ROLLBACK TO SAVEPOINT ir_sp_2", "RELEASE SAVEPOINT ir_sp_2"], executed
    end
  end

  test "Demo.fingerprint_stylesheets renames css files with a 10-character sha256 digest" do
    Dir.mktmpdir do |app|
      HostAdapters::Demo.fingerprint_stylesheets(app)

      dir = File.join(app, "app/assets/stylesheets")
      FileUtils.mkdir_p(dir)
      css_a = "body { color: #111; }\n"
      css_b = "h1 { font-size: 2rem; }\n"
      File.write(File.join(dir, "application.css"), css_a)
      File.write(File.join(dir, "reset.css"), css_b)
      File.write(File.join(dir, "README.txt"), "keep\n")

      HostAdapters::Demo.fingerprint_stylesheets(app)

      digest_a = Digest::SHA256.hexdigest(css_a)[0, 10]
      digest_b = Digest::SHA256.hexdigest(css_b)[0, 10]
      assert_equal ["README.txt", "application-#{digest_a}.css", "reset-#{digest_b}.css"], Dir.children(dir).sort
      assert_equal css_a, File.read(File.join(dir, "application-#{digest_a}.css"))
      assert_equal css_b, File.read(File.join(dir, "reset-#{digest_b}.css"))
    end
  end

  test "Demo.version_inbox_bundle versions inbox.js, is idempotent, and raises when target is missing" do
    Dir.mktmpdir do |app|
      bundle_path = File.join(app, "app/assets/builds/inbox.js")
      view_path = File.join(app, "app/views/email/mailboxes/index.html.erb")
      FileUtils.mkdir_p(File.dirname(bundle_path))
      FileUtils.mkdir_p(File.dirname(view_path))

      original_view = '<script src="<%= asset_path("inbox.js") %>"></script>' + "\n"
      File.write(view_path, original_view)
      HostAdapters::Demo.version_inbox_bundle(app)
      assert_equal original_view, File.read(view_path)

      bundle = "console.log('inbox');\n"
      digest = Digest::SHA256.hexdigest(bundle)[0, 10]
      File.write(bundle_path, bundle)

      HostAdapters::Demo.version_inbox_bundle(app)
      expected = %(<script src="/assets/inbox.js?v=#{digest}"></script>\n)
      assert_equal expected, File.read(view_path)

      HostAdapters::Demo.version_inbox_bundle(app)
      assert_equal expected, File.read(view_path)

      File.write(view_path, "<script src=\"/assets/other.js\"></script>\n")
      error = assert_raises(BuildError) { HostAdapters::Demo.version_inbox_bundle(app) }
      assert_equal "demo seam did not apply: app/views/email/mailboxes/index.html.erb", error.message
    end
  end

  test "Demo.adapt_demo_views rewrites application layout and prefixes non-partial views with demo_scope" do
    Dir.mktmpdir do |app|
      layout_path = File.join(app, "app/views/layouts/application.html.erb")
      other_layout_path = File.join(app, "app/views/layouts/mailer.html.erb")
      slack_view_path = File.join(app, "app/views/slack/channels/show.html.erb")
      email_view_path = File.join(app, "app/views/email/mailboxes/index.html.erb")
      partial_path = File.join(app, "app/views/slack/channels/_message.html.erb")

      [layout_path, other_layout_path, slack_view_path, email_view_path, partial_path].each do |p|
        FileUtils.mkdir_p(File.dirname(p))
      end

      File.write(layout_path, <<~ERB)
        <% demo = controller_path.split("/").first %>
        <body class="demo-<%= controller_path.split("/").first %>">
          <span class="micro-label">Local-first Rails demos —</span>
          <a href="<%= source_path(page: controller_path, view: action_name) %>">Read live out of app.wasm — not a snippet</a>
        </body>
      ERB
      File.write(other_layout_path, "<%= yield %>\n")
      File.write(slack_view_path, "<h1>Slack</h1>\n")
      File.write(email_view_path, "<h1>Email</h1>\n")
      File.write(partial_path, "<p>msg</p>\n")

      HostAdapters::Demo.adapt_demo_views(app)

      assert_equal <<~ERB, File.read(layout_path)
        <% demo = content_for(:demo_scope).to_s %>
        <body class="demo-<%= content_for(:demo_scope) %>">
          <span class="micro-label"><a href="/">All demos</a> ·</span>
          <a href="/source">View the source for this build</a>
        </body>
      ERB
      assert_equal "<%= yield %>\n", File.read(other_layout_path)
      assert_equal "<% content_for(:demo_scope, \"slack\") %>\n<h1>Slack</h1>\n", File.read(slack_view_path)
      assert_equal "<% content_for(:demo_scope, \"email\") %>\n<h1>Email</h1>\n", File.read(email_view_path)
      assert_equal "<p>msg</p>\n", File.read(partial_path)
    end
  end

  test "Demo.adapt_demo_views handles non-ASCII UTF-8 scope directories and view content without encoding errors" do
    Dir.mktmpdir do |app|
      view_path = File.join(app, "app/views/café/items/index.html.erb")
      FileUtils.mkdir_p(File.dirname(view_path))
      content = "<h1>Café — ☕</h1>\n"
      File.binwrite(view_path, content)

      HostAdapters::Demo.adapt_demo_views(app)

      expected = "<% content_for(:demo_scope, \"café\") %>\n#{content}".b
      assert_equal expected, File.binread(view_path)
    end
  end

  test "Demo.rewrite_server_url_helpers rewrites route helpers and literal paths and reports errors" do
    marker = InstantRecord::NETWORK_MARKER
    slack_rel = "app/helpers/slack_helper.rb"
    auth_rel = "app/helpers/auth_helper.rb"

    Dir.mktmpdir do |app|
      slack_path = File.join(app, slack_rel)
      auth_path = File.join(app, auth_rel)
      FileUtils.mkdir_p(File.dirname(slack_path))

      File.write(slack_path, <<~RUBY)
        module SlackHelper
          def reset_url = InstantRecord.server_url(slack_reset_path)
          def custom_url = InstantRecord.server_url("/custom/path")
          def untouched
            [
              InstantRecord.server_url(unknown_path),
              InstantRecord.server_url(slack_reset_path, :extra),
              InstantRecord.server_url(obj.slack_reset_path),
              Other.server_url("/other")
            ]
          end
        end
      RUBY
      File.write(auth_path, <<~RUBY)
        module AuthHelper
          def sign_in_url = ::InstantRecord.server_url(auth_session_path)
          def sign_out_url = InstantRecord.server_url(auth_session_sign_out_path)
        end
      RUBY

      HostAdapters::Demo.rewrite_server_url_helpers(app)

      assert_equal <<~RUBY, File.read(slack_path)
        module SlackHelper
          def reset_url = "/slack/reset?#{marker}"
          def custom_url = "/custom/path?#{marker}"
          def untouched
            [
              InstantRecord.server_url(unknown_path),
              InstantRecord.server_url(slack_reset_path, :extra),
              InstantRecord.server_url(obj.slack_reset_path),
              Other.server_url("/other")
            ]
          end
        end
      RUBY
      assert_equal <<~RUBY, File.read(auth_path)
        module AuthHelper
          def sign_in_url = "/auth/session?#{marker}"
          def sign_out_url = "/auth/session/sign_out?#{marker}"
        end
      RUBY
    end

    error = assert_raises(BuildError) do
      rewrite(slack_rel, "module SlackHelper\n  def x = 1\nend\n") { |app| HostAdapters::Demo.rewrite_server_url_helpers(app) }
    end
    assert_equal "demo seam did not apply: #{slack_rel}: no InstantRecord.server_url calls rewritten", error.message

    parse_error = assert_raises(BuildError) do
      rewrite(auth_rel, "def (") { |app| HostAdapters::Demo.rewrite_server_url_helpers(app) }
    end
    assert_equal "Cannot parse #{auth_rel}", parse_error.message
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
