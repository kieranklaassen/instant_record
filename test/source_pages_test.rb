# frozen_string_literal: true

require "test_helper"
require "cgi"
require "digest"
require "fileutils"
require "pathname"
require "tmpdir"
require "instant_record/compiler/source_pages"

class SourcePagesTest < ActiveSupport::TestCase
  GEM_ROOT = File.expand_path("..", __dir__)
  DEMO_DIR = File.join(GEM_ROOT, "demo")
  PIPELINE_DIR = File.join(GEM_ROOT, "compiled/pipeline")

  # Reference implementation matching the original unoptimized behavior verbatim.
  def reference_write(app_dir:, dist_dir:, version:, demo_dir:, pipeline_dir:)
    root = Pathname(app_dir)
    demo_root = Pathname(demo_dir)
    dest = Pathname(dist_dir).join("assets", "source", version)
    FileUtils.mkdir_p(dest)

    InstantRecord::Compiler::SourcePages::PAGES.each do |key, (controller, action, models)|
      files = models.map { |model| ["app/models/#{model}.rb", root.join("app/models/#{model}.rb")] }
      files << ["app/controllers/#{controller}_controller.rb", root.join("app/controllers/#{controller}_controller.rb")]
      files << ["app/views/#{controller}/#{action}.html.erb", root.join("app/views/#{controller}/#{action}.html.erb")]

      case key
      when "email"
        files << ["app/frontend/pages/Email/Inbox.jsx", demo_root.join("app/frontend/pages/Email/Inbox.jsx")]
      when "assistant"
        %w[
          app/javascript/controllers/assistant_chat_controller.js
          app/views/assistant/turns/_turns.html.erb
          app/javascript/controllers/assistant_local_model.js
        ].each { |part| files << [part, root.join(part)] }
        %w[app/jobs/assistant/reply_job.rb app/models/assistant/reply.rb].each do |server|
          files << [server, demo_root.join(server)]
        end
      when "auth"
        files << ["app/javascript/controllers/auth_controller.js", root.join("app/javascript/controllers/auth_controller.js")]
        %w[app/controllers/auth/sessions_controller.rb config/initializers/instant_record.rb].each do |server|
          files << [server, demo_root.join(server)]
        end
      when "migrate"
        files[1] = ["compiled/pipeline/sqlite_release.rb", Pathname(pipeline_dir).join("sqlite_release.rb")]
      end

      parts = ['<p class="source-note">Source used by this compiled build. Marked lines use InstantRecord.</p>']
      files.each do |label, path|
        lines = path.read.lines(chomp: true)
        marked = lines.count { |line| InstantRecord::Compiler::SourcePages::MARKER.match?(line) }
        parts << %(<section class="source-file"><header><span class="source-path">#{label}</span>) +
                 %(<span class="source-count">#{marked} InstantRecord lines of #{lines.length}</span></header><div class="source-code">)
        lines.each_with_index do |line, idx|
          css = InstantRecord::Compiler::SourcePages::MARKER.match?(line) ? " instant-record" : ""
          parts << %(<div class="source-line#{css}"><span class="source-ln">#{idx + 1}</span>) +
                   %(<span class="source-text">#{CGI.escapeHTML(line)}</span></div>)
        end
        parts << "</div></section>"
      end

      dest.join("#{key}.html").write(parts.join)
    end
  end

  # Scaffold a minimal tree containing every path SourcePages.write reads.
  def create_minimal_app(root, demo_root:, pipeline_root:, overrides: {})
    app_files = %w[
      app/models/assistant_chat.rb
      app/models/assistant_turn.rb
      app/models/auth_note.rb
      app/models/auth_person.rb
      app/models/mail_entry.rb
      app/models/mail_directory.rb
      app/models/issue.rb
      app/models/channel.rb
      app/models/chat_user.rb
      app/models/message.rb
      app/models/note.rb
      app/controllers/assistant/turns_controller.rb
      app/controllers/auth/notes_controller.rb
      app/controllers/home_controller.rb
      app/controllers/email/mailboxes_controller.rb
      app/controllers/todo/issues_controller.rb
      app/controllers/instant/todos_controller.rb
      app/controllers/slack/channels_controller.rb
      app/controllers/migrate/notes_controller.rb
      app/controllers/console/sessions_controller.rb
      app/controllers/receipts_controller.rb
      app/views/assistant/turns/index.html.erb
      app/views/assistant/turns/_turns.html.erb
      app/views/auth/notes/index.html.erb
      app/views/home/index.html.erb
      app/views/email/mailboxes/index.html.erb
      app/views/todo/issues/index.html.erb
      app/views/instant/todos/index.html.erb
      app/views/slack/channels/show.html.erb
      app/views/migrate/notes/index.html.erb
      app/views/console/sessions/index.html.erb
      app/views/receipts/index.html.erb
      app/javascript/controllers/assistant_chat_controller.js
      app/javascript/controllers/assistant_local_model.js
      app/javascript/controllers/auth_controller.js
    ]
    demo_files = %w[
      app/frontend/pages/Email/Inbox.jsx
      app/jobs/assistant/reply_job.rb
      app/models/assistant/reply.rb
      app/controllers/auth/sessions_controller.rb
      config/initializers/instant_record.rb
    ]

    app_files.each do |rel|
      full = File.join(root, rel)
      FileUtils.mkdir_p(File.dirname(full))
      File.binwrite(full, overrides.fetch(rel, "# #{rel}\n"))
    end
    demo_files.each do |rel|
      full = File.join(demo_root, rel)
      FileUtils.mkdir_p(File.dirname(full))
      File.binwrite(full, overrides.fetch(rel, "# #{rel}\n"))
    end
    pipe = File.join(pipeline_root, "sqlite_release.rb")
    FileUtils.mkdir_p(File.dirname(pipe))
    File.binwrite(pipe, overrides.fetch("compiled/pipeline/sqlite_release.rb", "# sqlite_release\n"))
  end

  test "write produces byte-for-byte identical HTML across all 10 demo pages" do
    Dir.mktmpdir do |dir|
      ref_dist = File.join(dir, "ref")
      opt_dist = File.join(dir, "opt")

      reference_write(
        app_dir: DEMO_DIR,
        dist_dir: ref_dist,
        version: "vtest",
        demo_dir: DEMO_DIR,
        pipeline_dir: PIPELINE_DIR
      )
      InstantRecord::Compiler::SourcePages.write(
        app_dir: DEMO_DIR,
        dist_dir: opt_dist,
        version: "vtest",
        demo_dir: DEMO_DIR,
        pipeline_dir: PIPELINE_DIR
      )

      InstantRecord::Compiler::SourcePages::PAGES.each_key do |page|
        ref_bytes = File.binread(File.join(ref_dist, "assets/source/vtest", "#{page}.html"))
        opt_bytes = File.binread(File.join(opt_dist, "assets/source/vtest", "#{page}.html"))
        assert_equal Digest::SHA256.hexdigest(ref_bytes), Digest::SHA256.hexdigest(opt_bytes), "SHA-256 mismatch for #{page}.html"
        assert_equal ref_bytes, opt_bytes, "Byte mismatch for #{page}.html"
      end
    end
  end

  test "write deduplicates reads of shared files like app/models/issue.rb across pages" do
    Dir.mktmpdir do |dir|
      read_counts = Hash.new(0)
      orig_read = File.method(:read)
      File.singleton_class.define_method(:read) do |path, *args, **kwargs|
        read_counts[path.to_s] += 1
        orig_read.call(path, *args, **kwargs)
      end

      begin
        InstantRecord::Compiler::SourcePages.write(
          app_dir: DEMO_DIR,
          dist_dir: dir,
          version: "dedup",
          demo_dir: DEMO_DIR,
          pipeline_dir: PIPELINE_DIR
        )
      ensure
        File.singleton_class.define_method(:read, orig_read)
      end

      issue_path = File.join(DEMO_DIR, "app/models/issue.rb")
      assert_equal 1, read_counts[issue_path], "Expected app/models/issue.rb to be read once across todo, instant, and console"

      todo_html = File.read(File.join(dir, "assets/source/dedup/todo.html"))
      instant_html = File.read(File.join(dir, "assets/source/dedup/instant.html"))
      console_html = File.read(File.join(dir, "assets/source/dedup/console.html"))
      [todo_html, instant_html, console_html].each do |html|
        assert_includes html, '<span class="source-path">app/models/issue.rb</span>'
      end

      # Per-call memoization must not persist stale content across separate write calls.
      app = File.join(dir, "fresh_app")
      demo = File.join(dir, "fresh_demo")
      pipe = File.join(dir, "fresh_pipe")
      create_minimal_app(app, demo_root: demo, pipeline_root: pipe, overrides: { "app/models/issue.rb" => "# version one\n" })
      InstantRecord::Compiler::SourcePages.write(app_dir: app, dist_dir: dir, version: "r1", demo_dir: demo, pipeline_dir: pipe)
      assert_includes File.read(File.join(dir, "assets/source/r1/todo.html")), "# version one"

      File.write(File.join(app, "app/models/issue.rb"), "# version two\n")
      InstantRecord::Compiler::SourcePages.write(app_dir: app, dist_dir: dir, version: "r2", demo_dir: demo, pipeline_dir: pipe)
      %w[todo instant console].each do |page|
        html = File.read(File.join(dir, "assets/source/r2", "#{page}.html"))
        assert_includes html, "# version two"
        refute_includes html, "# version one"
      end
    end
  end

  test "write matches reference for zero markers, single and multi marker families, near-misses, and HTML escaping" do
    Dir.mktmpdir do |dir|
      app = File.join(dir, "app")
      demo = File.join(dir, "demo")
      pipe = File.join(dir, "pipe")
      ref_dist = File.join(dir, "ref")
      opt_dist = File.join(dir, "opt")

      overrides = {
        "app/controllers/home_controller.rb" => "class HomeController\n  def index\n    # plain code with <b>&\"'</b>\n  end\nend\n",
        "app/views/home/index.html.erb" => "<div data-x=\"a&b\" data-y='c<d>e'>Hello &amp; world</div>\n",
        "app/models/issue.rb" => <<~RUBY,
          class Issue < ApplicationRecord
            include InstantRecord::Syncable
            InstantRecord.sync(self)
            server_only { validate :quota }
            browser_only { local_hook }
            client_only { client_hook }
            sync_window limit: 50
            def status = sync_state
            def count = pending_count
            on_discarded_change { |r| r }
            # Near-misses that must NOT match:
            InstantRecord_suffix
            my_server_only
            server_only_extra
            sync_window2
            éserver_only
            pending_count_total
            on_discarded_change_hook
            # Markers directly adjacent to HTML special chars:
            <server_only>&sync_state'InstantRecord.foo"pending_count>
          end
        RUBY
        "app/controllers/receipts_controller.rb" => "InstantRecord.config.endpoint = \"/sync\"\nplain_line\n",
        "app/views/receipts/index.html.erb" => "<%= sync_window(limit: 10) %>\n<span>ok</span>\n",
        "app/models/note.rb" => "server_only do\n  puts 'hi'\nend\n",
        "app/models/channel.rb" => "InstantRecord.sync(Channel)\nsync_state\n"
      }

      create_minimal_app(app, demo_root: demo, pipeline_root: pipe, overrides: overrides)
      reference_write(app_dir: app, dist_dir: ref_dist, version: "edge", demo_dir: demo, pipeline_dir: pipe)
      InstantRecord::Compiler::SourcePages.write(app_dir: app, dist_dir: opt_dist, version: "edge", demo_dir: demo, pipeline_dir: pipe)

      InstantRecord::Compiler::SourcePages::PAGES.each_key do |page|
        ref_bytes = File.binread(File.join(ref_dist, "assets/source/edge", "#{page}.html"))
        opt_bytes = File.binread(File.join(opt_dist, "assets/source/edge", "#{page}.html"))
        assert_equal ref_bytes, opt_bytes, "Mismatch for #{page}.html"
      end

      home_html = File.read(File.join(opt_dist, "assets/source/edge/home.html"))
      assert_includes home_html, "0 InstantRecord lines of 5"
      assert_includes home_html, "&lt;b&gt;&amp;&quot;&#39;&lt;/b&gt;"

      todo_html = File.read(File.join(opt_dist, "assets/source/edge/todo.html"))
      assert_includes todo_html, "10 InstantRecord lines of 21"
      assert_includes todo_html, "&lt;server_only&gt;&amp;sync_state&#39;InstantRecord.foo&quot;pending_count&gt;"
    end
  end

  test "write matches reference on CRLF, LF, trailing CR, embedded CR, missing trailing newline, empty, and >2048-line files" do
    Dir.mktmpdir do |dir|
      app = File.join(dir, "app")
      demo = File.join(dir, "demo")
      pipe = File.join(dir, "pipe")
      ref_dist = File.join(dir, "ref")
      opt_dist = File.join(dir, "opt")

      long_unmarked = (1..2100).map { |i| "line_#{i} <tag attr=\"#{i}\"> & 'ok'" }.join("\n")
      long_marked = (1..2100).map do |i|
        if i == 1 || i == 2048 || i == 2049 || i == 2100
          "InstantRecord.sync(Row#{i}) # sync_state & <#{i}>"
        else
          "plain_#{i} & \"x\""
        end
      end.join("\n")

      overrides = {
        "app/controllers/home_controller.rb" => "",
        "app/views/home/index.html.erb" => "\n",
        "app/controllers/receipts_controller.rb" => "first\r\nInstantRecord.sync(R)\r\nthird & <ok>\r\n",
        "app/views/receipts/index.html.erb" => "no_trailing_newline InstantRecord:ok",
        "app/models/note.rb" => "alpha\rbeta\nserver_only\r",
        "app/controllers/migrate/notes_controller.rb" => "\r\n",
        "app/views/migrate/notes/index.html.erb" => "\r",
        "app/models/channel.rb" => long_unmarked,
        "app/models/message.rb" => long_marked
      }

      create_minimal_app(app, demo_root: demo, pipeline_root: pipe, overrides: overrides)
      reference_write(app_dir: app, dist_dir: ref_dist, version: "crlf", demo_dir: demo, pipeline_dir: pipe)
      InstantRecord::Compiler::SourcePages.write(app_dir: app, dist_dir: opt_dist, version: "crlf", demo_dir: demo, pipeline_dir: pipe)

      InstantRecord::Compiler::SourcePages::PAGES.each_key do |page|
        ref_bytes = File.binread(File.join(ref_dist, "assets/source/crlf", "#{page}.html"))
        opt_bytes = File.binread(File.join(opt_dist, "assets/source/crlf", "#{page}.html"))
        assert_equal ref_bytes, opt_bytes, "Mismatch for #{page}.html"
      end

      home_html = File.read(File.join(opt_dist, "assets/source/crlf/home.html"))
      assert_includes home_html, '<span class="source-count">0 InstantRecord lines of 0</span></header><div class="source-code"></div></section>'
      assert_includes home_html, '<span class="source-count">0 InstantRecord lines of 1</span>'

      slack_html = File.read(File.join(opt_dist, "assets/source/crlf/slack.html"))
      assert_includes slack_html, "0 InstantRecord lines of 2100"
      assert_includes slack_html, "4 InstantRecord lines of 2100"
      assert_includes slack_html, '<div class="source-line instant-record"><span class="source-ln">2049</span>'
      assert_includes slack_html, '<div class="source-line instant-record"><span class="source-ln">2100</span>'
    end
  end

  test "write substitutes compiled/pipeline/sqlite_release.rb for migrate without reading app/models/release.rb and accepts Pathname arguments" do
    Dir.mktmpdir do |dir|
      app = File.join(dir, "app")
      demo = File.join(dir, "demo")
      pipe = File.join(dir, "pipe")
      dist = File.join(dir, "dist")

      create_minimal_app(
        app,
        demo_root: demo,
        pipeline_root: pipe,
        overrides: {
          "app/models/note.rb" => "# note model\n",
          "compiled/pipeline/sqlite_release.rb" => "InstantRecord::SQLiteRelease\n# from pipeline\n"
        }
      )
      # Confirm app/models/release.rb does not exist — migrate must read pipeline_dir/sqlite_release.rb instead.
      refute File.exist?(File.join(app, "app/models/release.rb"))

      InstantRecord::Compiler::SourcePages.write(
        app_dir: Pathname(app),
        dist_dir: Pathname(dist),
        version: "p1",
        demo_dir: Pathname(demo),
        pipeline_dir: Pathname(pipe)
      )

      migrate_html = File.read(File.join(dist, "assets/source/p1/migrate.html"))
      paths = migrate_html.scan(%r{<span class="source-path">([^<]+)</span>}).flatten
      assert_equal(
        [
          "app/models/note.rb",
          "compiled/pipeline/sqlite_release.rb",
          "app/controllers/migrate/notes_controller.rb",
          "app/views/migrate/notes/index.html.erb"
        ],
        paths
      )
      assert_includes migrate_html, "1 InstantRecord lines of 2"
      assert_includes migrate_html, "# from pipeline"
    end
  end
end
