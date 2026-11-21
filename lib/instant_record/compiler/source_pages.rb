require "cgi"
require "fileutils"
require "pathname"

module InstantRecord
  class Compiler
    # Build lazy source drawers from the same app copy Roundhouse compiled.
    module SourcePages
      PAGES = {
        "assistant" => ["assistant/turns", "index", %w[assistant_chat assistant_turn]],
        "auth" => ["auth/notes", "index", %w[auth_note auth_person]],
        "home" => ["home", "index", []],
        "email" => ["email/mailboxes", "index", %w[mail_entry mail_directory]],
        "todo" => ["todo/issues", "index", %w[issue]],
        "slack" => ["slack/channels", "show", %w[channel chat_user message]],
        "migrate" => ["migrate/notes", "index", %w[note release]],
        "console" => ["console/sessions", "index", %w[issue]],
        "receipts" => ["receipts", "index", []]
      }.freeze

      MARKER = /InstantRecord[.:]|\b(?:server_only|browser_only|client_only|sync_window|sync_state|pending_count|on_discarded_change)\b/

      module_function

      def write(app_dir:, dist_dir:, version:, demo_dir:, pipeline_dir:)
        root = Pathname(app_dir)
        dest = Pathname(dist_dir).join("assets", "source", version)
        FileUtils.mkdir_p(dest)

        PAGES.each do |key, (controller, action, models)|
          files = models.map { |model| ["app/models/#{model}.rb", root.join("app/models/#{model}.rb")] }
          files << ["app/controllers/#{controller}_controller.rb", root.join("app/controllers/#{controller}_controller.rb")]
          files << ["app/views/#{controller}/#{action}.html.erb", root.join("app/views/#{controller}/#{action}.html.erb")]

          if %w[assistant email].include?(key)
            script = key == "assistant" ? "app/javascript/controllers/assistant_chat_controller.js" : "app/frontend/pages/Email/Inbox.jsx"
            files << [script, root.join(script)]
          end

          if key == "assistant"
            %w[app/views/assistant/turns/_turns.html.erb app/javascript/controllers/assistant_local_model.js].each do |part|
              files << [part, root.join(part)]
            end
            %w[app/jobs/assistant/reply_job.rb app/models/assistant/reply.rb].each do |server|
              files << [server, Pathname(demo_dir).join(server)]
            end
          end

          if key == "auth"
            files << ["app/javascript/controllers/auth_controller.js", root.join("app/javascript/controllers/auth_controller.js")]
            %w[app/controllers/auth/sessions_controller.rb config/initializers/instant_record.rb].each do |server|
              files << [server, Pathname(demo_dir).join(server)]
            end
          end

          if key == "migrate"
            files[1] = ["compiled/pipeline/sqlite_release.rb", Pathname(pipeline_dir).join("sqlite_release.rb")]
          end

          parts = ['<p class="source-note">Source used by this compiled build. Marked lines use InstantRecord.</p>']
          files.each do |label, path|
            lines = path.read.lines(chomp: true)
            marked = lines.count { |line| MARKER.match?(line) }
            parts << %(<section class="source-file"><header><span class="source-path">#{label}</span>) +
                     %(<span class="source-count">#{marked} InstantRecord lines of #{lines.length}</span></header><div class="source-code">)
            lines.each_with_index do |line, idx|
              css = MARKER.match?(line) ? " instant-record" : ""
              parts << %(<div class="source-line#{css}"><span class="source-ln">#{idx + 1}</span>) +
                       %(<span class="source-text">#{CGI.escapeHTML(line)}</span></div>)
            end
            parts << "</div></section>"
          end

          dest.join("#{key}.html").write(parts.join)
        end
      end
    end
  end
end
