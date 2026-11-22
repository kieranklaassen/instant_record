require "digest"
require "fileutils"
require "pathname"
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
        lib/instant_record/syncable.rb
        lib/instant_record/outbox_mutation.rb
        lib/instant_record/sync_metadata.rb
        lib/instant_record/hlc.rb
        lib/instant_record/sync_window.rb
        lib/instant_record/client.rb
        lib/instant_record/client/transport.rb
        lib/instant_record/client/notifier.rb
        lib/instant_record/native/node.rb
        lib/instant_record/native/screen.rb
      ].freeze

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
        unnest_syncable_concern
        write_sqlite_database_yml
        rewrite_scoped_blocks
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
          "      klass = record_type.to_s.safe_constantize\n      klass if klass.respond_to?(:instant_record_syncable?) && klass.instant_record_syncable?\n" => "      nil\n"
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

        # The compiled models give a new record an empty-string id, not nil.
        edit!("app/models/concerns/syncable.rb", "self.id ||= SecureRandom.uuid", "self.id = SecureRandom.uuid if id.blank?")

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
            changed = strip_server_only(source)
            changed = unwrap_client_only(changed)
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

      def strip_server_only(source)
        source.gsub(/(?<=\n|\A)( *)server_only do\n.*?\n\1end\n?/m, "")
      end

      def unwrap_client_only(source)
        source.gsub(/(?<=\n|\A)( *)(?:browser|client)_only do\n(.*?)\n\1end(?=\n|\z)/m) do
          indent = Regexp.last_match(1)
          Regexp.last_match(2).split("\n", -1).map do |line|
            line.start_with?("#{indent}  ") ? line[2..] : line
          end.join("\n")
        end
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
