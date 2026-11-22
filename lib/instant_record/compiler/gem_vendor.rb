require "digest"
require "fileutils"
require "pathname"
require "prism"
require_relative "runner"

module InstantRecord
  class Compiler
    # Vendors the instant_record gem's Ruby into the staged app's lib/, then
    # applies the ahead-of-time host seams where the gem talks to Rails or uses
    # runtime metaprogramming.
    class GemVendor
      COPY = %w[
        lib/instant_record.rb
        lib/instant_record/version.rb
        lib/instant_record/configuration.rb
        lib/instant_record/runtime_scoped.rb
        lib/instant_record/sync_actions.rb
        lib/instant_record/syncable.rb
        lib/instant_record/outbox_mutation.rb
        lib/instant_record/sync_metadata.rb
        lib/instant_record/sync_window.rb
        lib/instant_record/client.rb
        lib/instant_record/client/transport.rb
        lib/instant_record/client/notifier.rb
        lib/instant_record/branch.rb
        lib/instant_record/native/node.rb
        lib/instant_record/native/screen.rb
      ].freeze

      SPINEL_SYNC_ACTIONS_STUB = <<~'RUBY'
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

      SPINEL_SAVEPOINT_SEAM = <<~'RUBY'
        # Host seam (see GemVendor): native SQLite SAVEPOINT for compiled builds.
        def with_savepoint(&block)
          @savepoint_seq = (@savepoint_seq || 0) + 1
          sp = "ir_sp_" + @savepoint_seq.to_s
          Db.exec("SAVEPOINT " + sp)
          begin
            result = block.call
            Db.exec("RELEASE SAVEPOINT " + sp)
            result
          rescue StandardError => error
            Db.exec("ROLLBACK TO SAVEPOINT " + sp)
            Db.exec("RELEASE SAVEPOINT " + sp)
            raise error
          end
        end
      RUBY

      RUNTIME_SCOPED_SEAM = <<~RUBY
        module InstantRecord
          # Host seam (see GemVendor): the gem evaluates these blocks with class_eval, which cannot be
          # compiled ahead of time. This build is the browser, so server_only never runs.
          module RuntimeScoped
            def server_only(&block)
              nil
            end

            def browser_only(&block)
              nil
            end

            def client_only(&block)
              nil
            end
          end
        end
      RUBY

      SQLITE_DATABASE_YML = <<~YAML
        default: &default
          adapter: sqlite3
          database: storage/development.sqlite3

        development:
          <<: *default

        production:
          <<: *default
      YAML

      def self.vendor(gem_src:, app_dir:, demo: false)
        new(gem_src: gem_src, app_dir: app_dir, demo: demo).run
      end

      def initialize(gem_src:, app_dir:, demo: false)
        @gem = gem_src.to_s
        @app = app_dir.to_s
        @demo = demo
      end

      def run
        copy_gem_files
        apply_core_seams
        rewrite_scoped_blocks
        unnest_syncable_concern
        write_sqlite_database_yml
        apply_demo_seams if @demo
        COPY.length + 1
      end

      private

      def copy_gem_files
        FileUtils.rm_rf(File.join(@app, "lib/instant_record"))
        COPY.each do |rel|
          target = File.join(@app, rel)
          FileUtils.mkdir_p(File.dirname(target))
          FileUtils.cp(File.join(@gem, rel), target)
        end
        FileUtils.mkdir_p(File.join(@app, "app/models/instant_record"))
        FileUtils.cp(
          File.join(@gem, "app/models/instant_record/change.rb"),
          File.join(@app, "app/models/instant_record/change.rb")
        )
      end

      def apply_core_seams
        # The staged source runs exclusively in the compiled runtime.
        edit_all!("lib/instant_record.rb", {
          "def browser? = false" => "def browser? = true",
          "require \"instant_record/engine\" if defined?(Rails::Engine)\n" => "",
          "  require \"instant_record/branch/sqlite_store\"\n" => "",
          "      klass = record_type.to_s.safe_constantize\n      klass if klass.respond_to?(:instant_record_syncable?) && klass.instant_record_syncable?\n" => "      nil\n",
          "    def mutate(mutator_name, args = nil, mutation_id: nil, **kwargs)\n      merged = args ? (kwargs.empty? ? args : args.merge(kwargs)) : kwargs\n      SyncActions.mutate(mutator_name, merged, mutation_id: mutation_id)\n    end\n" => "    def mutate(mutator_name, args = {}, mutation_id: nil)\n      SyncActions.mutate(mutator_name, args, mutation_id: mutation_id)\n    end\n",
          "\nActiveSupport.on_load(:active_job) do\n  require \"instant_record/sync_actions\"\n  InstantRecord::SyncActions.install_active_job_guard!\nend\n" => "\n"
        })

        # Model discovery: ActiveRecord::Base.descendants has no AOT counterpart;
        # the gem's explicit allowlist (InstantRecord.sync) takes its place.
        cut!(
          "lib/instant_record.rb",
          "      ActiveRecord::Base.descendants.select do |model|",
          "    end\n\n    # One record's attributes as they cross the wire",
          "      []\n"
        )

        # Roundhouse's Rails.application.config has no instant_record option;
        # EntryBuilder sets config.mount_path at boot instead.
        cut!(
          "lib/instant_record.rb",
          "      configured =\n        if defined?(Rails)",
          "    end\n\n    # The retry decision must survive",
          "      DEFAULT_MOUNT_PATH\n"
        )

        # sync_actions: strip CRuby server-only frame, ActiveJob guard, and dynamic
        # dispatch; EntryBuilder emits the static `case` dispatcher in main_*.rb.
        cut!(
          "lib/instant_record/sync_actions.rb",
          "    # --- cruby-server-frame:start ---\n",
          "    # --- cruby-server-frame:end ---\n",
          ""
        )
        edit!("lib/instant_record/sync_actions.rb", "    # --- cruby-server-frame:end ---\n", "")
        cut!(
          "lib/instant_record/sync_actions.rb",
          "      # --- cruby-only:start ---\n",
          "      # --- cruby-only:end ---\n",
          SPINEL_SYNC_ACTIONS_STUB.lines.map { |l| l.strip.empty? ? "\n" : "      #{l}" }.join
        )
        edit!("lib/instant_record/sync_actions.rb", "      # --- cruby-only:end ---\n", "")
        edit_all!("lib/instant_record/sync_actions.rb", {
          "      def perform_sync_action(action_name, args = nil, mutation_id: nil, **kwargs)\n        merged = args ? (kwargs.empty? ? args : args.merge(kwargs)) : kwargs\n        InstantRecord::SyncActions.mutate(\"\#{name}.\#{action_name}\", merged, mutation_id: mutation_id)\n      end\n" => "      def perform_sync_action(action_name, args = {}, mutation_id: nil)\n        InstantRecord::SyncActions.mutate(\"\#{name}.\#{action_name}\", args, mutation_id: mutation_id)\n      end\n",
          "      def mutate(mutator_name, args = nil, mutation_id: nil, **kwargs)\n        name = mutator_name.to_s\n        merged = args ? (kwargs.empty? ? args : args.merge(kwargs)) : kwargs\n        normalized = normalize_args(merged)\n" => "      def mutate(mutator_name, args = {}, mutation_id: nil)\n        name = mutator_name.to_s\n        normalized = normalize_args(args)\n",
          "      # GemVendor replaces this method in compiled builds with native SQLite SAVEPOINT.\n      def with_savepoint(&block)\n        ActiveRecord::Base.transaction(requires_new: true, &block)\n      end\n" => SPINEL_SAVEPOINT_SEAM.lines.map { |l| l.strip.empty? ? "\n" : "      #{l}" }.join
        })

        # Screens are found by name through a generated `case` (EntryBuilder), not constant lookup.
        FileUtils.mkdir_p(File.join(@app, "sig/instant_record"))
        FileUtils.cp(
          File.join(@gem, "sig/instant_record/native.rbs"),
          File.join(@app, "sig/instant_record/native.rbs")
        )
        File.write(
          File.join(@app, "lib/instant_record/native.rb"),
          "require \"instant_record/native/node\"\nrequire \"instant_record/native/screen\"\n"
        )

        # server_only / browser_only / client_only are unwrapped statically below.
        File.write(File.join(@app, "lib/instant_record/runtime_scoped.rb"), RUNTIME_SCOPED_SEAM)
      end

      def unnest_syncable_concern
        path = File.join(@app, "lib/instant_record/syncable.rb")
        lines = File.read(path).sub(/\n+\z/, "").split("\n", -1)
        start = lines.index("module InstantRecord")
        raise BuildError, "Unexpected structure in #{path}" unless start && lines.last == "end"

        inner = lines[(start + 1)...-1].map { |line| line.start_with?("  ") ? line[2..] : line }
        body = lines[0...start] + inner

        concerns_dir = File.join(@app, "app/models/concerns")
        FileUtils.mkdir_p(concerns_dir)
        FileUtils.rm_rf(File.join(concerns_dir, "instant_record"))
        File.write(File.join(concerns_dir, "syncable.rb"), body.join("\n") + "\n")
        File.delete(path)

        models_dir = File.join(@app, "app/models")
        if File.directory?(models_dir)
          Dir.glob("**/*.rb", base: models_dir).sort.each do |rel|
            target = File.join(models_dir, rel)
            source = File.read(target)
            adapted = source.gsub("include InstantRecord::Syncable", "include Syncable")
            File.write(target, adapted) if adapted != source
          end
        end
      end

      def write_sqlite_database_yml
        config_dir = File.join(@app, "config")
        FileUtils.mkdir_p(config_dir)
        File.write(File.join(config_dir, "database.yml"), SQLITE_DATABASE_YML)
      end

      def rewrite_scoped_blocks
        %w[app/models app/controllers app/helpers app/screens].each do |subdir|
          root = File.join(@app, subdir)
          next unless File.directory?(root)

          Dir.glob("**/*.rb", base: root).sort.each do |rel|
            target = File.join(root, rel)
            source = File.read(target)
            changed = rewrite_runtime_blocks(source)
            File.write(target, changed) if changed != source
          end
        end
      end

      def apply_demo_seams
        # Content-hash stylesheets so returning tabs pick up responsive fixes.
        stylesheets_dir = File.join(@app, "app/assets/stylesheets")
        if File.directory?(stylesheets_dir)
          Dir.glob("*.css", base: stylesheets_dir).sort.each do |name|
            sheet = File.join(stylesheets_dir, name)
            digest = Digest::SHA256.file(sheet).hexdigest[0, 10]
            ext = File.extname(sheet)
            stem = File.basename(sheet, ext)
            File.rename(sheet, File.join(stylesheets_dir, "#{stem}-#{digest}#{ext}"))
          end
        end

        # Version the Inbox React bundle URL by its content digest.
        bundle = File.join(@app, "app/assets/builds/inbox.js")
        if File.file?(bundle)
          digest = Digest::SHA256.file(bundle).hexdigest[0, 10]
          edit!(
            "app/views/email/mailboxes/index.html.erb",
            '<%= asset_path("inbox.js") %>',
            "/assets/inbox.js?v=#{digest}"
          )
        end

        # Adapt the demo layout for static source drawers and content_for(:demo_scope).
        layout_path = File.join(@app, "app/views/layouts/application.html.erb")
        source = File.read(layout_path)
        source = source.gsub('<span class="micro-label">Local-first Rails demos —', '<span class="micro-label"><a href="/">All demos</a> ·')
        source = source.gsub('<%= source_path(page: controller_path, view: action_name) %>', "/source")
        source = source.gsub("Read live out of app.wasm — not a snippet", "View the source for this build")
        source = source.gsub('demo-<%= controller_path.split("/").first %>', "demo-<%= content_for(:demo_scope) %>")
        source = source.gsub('<% demo = controller_path.split("/").first %>', "<% demo = content_for(:demo_scope).to_s %>")
        File.write(layout_path, source)

        views_dir = File.join(@app, "app/views")
        views_root = Pathname(views_dir)
        Dir.glob("**/*.html.erb", base: views_dir).sort.each do |rel|
          view = views_root.join(rel)
          next if view.basename.to_s.start_with?("_") || view.parent.basename.to_s == "layouts"

          scope = Pathname(rel).each_filename.first
          view.write("<% content_for(:demo_scope, \"#{scope}\") %>\n" + view.read)
        end

        # Route server-only actions through the worker's network marker.
        edit!("app/helpers/slack_helper.rb", "InstantRecord.server_url(slack_reset_path)", '"/slack/reset?instant_record_network=1"')
        edit_all!("app/helpers/auth_helper.rb", {
          "InstantRecord.server_url(auth_session_path)" => '"/auth/session?instant_record_network=1"',
          "InstantRecord.server_url(auth_session_sign_out_path)" => '"/auth/session/sign_out?instant_record_network=1"',
          'InstantRecord.server_url("/instant_record/bootstrap")' => '"/instant_record/bootstrap?instant_record_network=1"',
          'InstantRecord.server_url("/instant_record/mutations")' => '"/instant_record/mutations?instant_record_network=1"'
        })

        # Compiled code needs a single type across both branches of the ternary.
        edit!(
          "app/controllers/slack/channels_controller.rb",
          "@thread_parent.replies.includes(:chat_user).order(:created_at, :id) : []",
          "@thread_parent.replies.includes(:chat_user).order(:created_at, :id).to_a : []"
        )
      end

      # Prism-based rewriter: strips `server_only` blocks and unwraps
      # `browser_only`/`client_only` blocks (both `do...end` and `{...}`).
      def rewrite_runtime_blocks(source)
        return source unless source.include?("server_only") || source.include?("browser_only") || source.include?("client_only")

        parsed = Prism.parse(source)
        return source unless parsed.success?

        edits = []
        collect_scoped_block_edits(parsed.value, source, edits)
        return source if edits.empty?

        result = source.b
        edits.sort_by { |e| -e[:start] }.each do |edit|
          result[edit[:start]...edit[:finish]] = edit[:replacement].b
        end
        result.force_encoding(source.encoding)
      end

      def collect_scoped_block_edits(node, source, edits)
        return unless node

        if node.is_a?(Prism::CallNode) && node.receiver.nil? && node.block.is_a?(Prism::BlockNode) &&
            %i[server_only browser_only client_only].include?(node.name)
          start_off, end_off, indent = line_bounds(source, node.location.start_offset, node.location.end_offset)
          replacement =
            if node.name == :server_only
              ""
            else
              unwrap_block_body(node.block, source, indent)
            end
          edits << { start: start_off, finish: end_off, replacement: replacement }
          return
        end

        node.compact_child_nodes.each { |child| collect_scoped_block_edits(child, source, edits) }
      end

      def line_bounds(source, start_off, end_off)
        bytes = source.b
        line_start = bytes.rindex("\n", start_off)
        line_start = line_start ? line_start + 1 : 0
        prefix = bytes[line_start...start_off]
        full_line = prefix.match?(/\A[ \t]*\z/)
        indent = full_line ? prefix : ""
        effective_start = full_line ? line_start : start_off
        effective_end = end_off
        effective_end += 1 if full_line && bytes.getbyte(effective_end) == 10 # trailing "\n"
        [effective_start, effective_end, indent]
      end

      def unwrap_block_body(block, source, indent)
        return "" unless block.body

        bytes = source.b
        open_end = block.opening_loc.end_offset
        close_start = block.closing_loc.start_offset
        inner = bytes[open_end...close_start]
        # Drop leading comment/newline on the `do` line and trailing whitespace before `end`.
        inner = inner.sub(/\A[^\n]*\n/, "") if inner.include?("\n")
        inner = inner.sub(/\n[ \t]*\z/, "\n")
        lines = inner.split("\n", -1)
        lines.pop if lines.last == ""
        unwrapped = lines.map do |line|
          if line.strip.empty?
            ""
          elsif line.start_with?("#{indent}  ")
            line[2..]
          else
            "#{indent}#{line.lstrip}"
          end
        end
        unwrapped.empty? ? "" : "#{unwrapped.join("\n")}\n"
      end

      def edit!(rel, old, replacement)
        edit_all!(rel, { old => replacement })
      end

      def edit_all!(rel, replacements)
        path = File.join(@app, rel)
        source = File.read(path)
        updated = source
        replacements.each do |old, replacement|
          unless updated.include?(old)
            next if !replacement.empty? && updated.include?(replacement)

            raise BuildError, "seam did not apply: #{rel}: #{old[0, 60].inspect}"
          end
          updated = updated.sub(old) { replacement }
        end
        File.write(path, updated) if updated != source
      end

      def cut!(rel, start_marker, end_marker, replacement)
        path = File.join(@app, rel)
        source = File.read(path)
        a = source.index(start_marker)
        b = a && source.index(end_marker, a)
        raise BuildError, "seam cut did not apply: #{rel}: #{start_marker[0, 60].inspect}" unless a && b

        File.write(path, source[0...a] + replacement + source[b..])
      end
    end
  end
end
