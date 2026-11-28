# frozen_string_literal: true

require "cgi"
require "fileutils"

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
        "instant" => ["instant/todos", "index", %w[issue]],
        "slack" => ["slack/channels", "show", %w[channel chat_user message]],
        "migrate" => ["migrate/notes", "index", %w[note release]],
        "console" => ["console/sessions", "index", %w[issue]],
        "receipts" => ["receipts", "index", []]
      }.freeze

      MARKER = /InstantRecord[.:]|\b(?:server_only|browser_only|client_only|sync_window|sync_state|pending_count|on_discarded_change)\b/

      SOURCE_NOTE = '<p class="source-note">Source used by this compiled build. Marked lines use InstantRecord.</p>'
      SECTION_OPEN = '<section class="source-file"><header><span class="source-path">'
      SECTION_MID1 = '</span><span class="source-count">'
      SECTION_MID2 = " InstantRecord lines of "
      SECTION_MID3 = '</span></header><div class="source-code">'
      SECTION_CLOSE = "</div></section>"
      LINE_CLOSE = "</span></div>"
      LINE_END_SECTION_CLOSE = "</span></div></div></section>"
      LINE_OPEN = '<div class="source-line"><span class="source-ln">'
      MARKED_LINE_OPEN = '<div class="source-line instant-record"><span class="source-ln">'
      LINE_TEXT_OPEN = '</span><span class="source-text">'

      TABLE_LIMIT = 2048
      LINE_OPEN_FIRST = '<div class="source-line"><span class="source-ln">1</span><span class="source-text">'
      MARKED_LINE_OPEN_FIRST = '<div class="source-line instant-record"><span class="source-ln">1</span><span class="source-text">'
      LINE_SEP = Array.new(TABLE_LIMIT) do |i|
        i == 0 ? LINE_OPEN_FIRST : %(</span></div><div class="source-line"><span class="source-ln">#{i + 1}</span><span class="source-text">).freeze
      end.freeze
      MARKED_LINE_SEP = Array.new(TABLE_LIMIT) do |i|
        i == 0 ? MARKED_LINE_OPEN_FIRST : %(</span></div><div class="source-line instant-record"><span class="source-ln">#{i + 1}</span><span class="source-text">).freeze
      end.freeze
      LINE_NUMS = Array.new(TABLE_LIMIT + 1) { |i| i.to_s.freeze }.freeze

      MARKER_RE_IR = /InstantRecord[.:]/
      MARKER_RE_ONLY = /\b(?:server|browser|client)_only\b/
      MARKER_RE_SYNC = /\bsync_(?:window|state)\b/
      MARKER_RE_PEND = /\bpending_count\b/
      MARKER_RE_DISC = /\bon_discarded_change\b/

      SINGLE_FAMILY = {
        1 => ["InstantRecord", MARKER_RE_IR].freeze,
        2 => ["_only", MARKER_RE_ONLY].freeze,
        4 => ["sync_", MARKER_RE_SYNC].freeze,
        8 => ["pending_count", MARKER_RE_PEND].freeze,
        16 => ["on_discarded_change", MARKER_RE_DISC].freeze
      }.freeze

      UNDER_SINGLE = {
        1 => ["_only", MARKER_RE_ONLY].freeze,
        2 => ["sync_", MARKER_RE_SYNC].freeze,
        4 => ["pending_count", MARKER_RE_PEND].freeze,
        8 => ["on_discarded_change", MARKER_RE_DISC].freeze
      }.freeze

      # Precomputed per-page file specs: [filename, [[label, root_kind, rel_path, cache_key], ...]]
      PAGE_SPECS = begin
        raw_specs = {}
        counts = Hash.new(0)

        PAGES.each do |key, (controller, action, models)|
          files = models.map do |model|
            rel = "app/models/#{model}.rb".freeze
            [rel, :app, rel]
          end
          ctrl = "app/controllers/#{controller}_controller.rb".freeze
          view = "app/views/#{controller}/#{action}.html.erb".freeze
          files << [ctrl, :app, ctrl]
          files << [view, :app, view]

          case key
          when "email"
            rel = "app/frontend/pages/Email/Inbox.jsx"
            files << [rel, :demo, rel]
          when "assistant"
            %w[
              app/javascript/controllers/assistant_chat_controller.js
              app/views/assistant/turns/_turns.html.erb
              app/javascript/controllers/assistant_local_model.js
            ].each { |part| files << [part.freeze, :app, part.freeze] }
            %w[app/jobs/assistant/reply_job.rb app/models/assistant/reply.rb].each do |server|
              files << [server.freeze, :demo, server.freeze]
            end
          when "auth"
            js = "app/javascript/controllers/auth_controller.js"
            files << [js, :app, js]
            %w[app/controllers/auth/sessions_controller.rb config/initializers/instant_record.rb].each do |server|
              files << [server.freeze, :demo, server.freeze]
            end
          when "migrate"
            files[1] = ["compiled/pipeline/sqlite_release.rb", :pipeline, "sqlite_release.rb"]
          end

          files.each { |triple| counts[triple] += 1 }
          raw_specs[key] = files
        end

        raw_specs.map do |key, files|
          specs = files.map do |triple|
            label, root_kind, rel_path = triple
            cache_key = counts[triple] > 1 ? [label, root_kind, rel_path].freeze : nil
            [label, root_kind, rel_path, cache_key].freeze
          end.freeze
          ["#{key}.html".freeze, specs].freeze
        end.freeze
      end

      private_constant :SOURCE_NOTE, :SECTION_OPEN, :SECTION_MID1, :SECTION_MID2, :SECTION_MID3,
                       :SECTION_CLOSE, :LINE_CLOSE, :LINE_END_SECTION_CLOSE, :LINE_OPEN,
                       :MARKED_LINE_OPEN, :LINE_TEXT_OPEN, :TABLE_LIMIT, :LINE_OPEN_FIRST,
                       :MARKED_LINE_OPEN_FIRST, :LINE_SEP, :MARKED_LINE_SEP, :LINE_NUMS,
                       :MARKER_RE_IR, :MARKER_RE_ONLY, :MARKER_RE_SYNC, :MARKER_RE_PEND,
                       :MARKER_RE_DISC, :SINGLE_FAMILY, :UNDER_SINGLE, :PAGE_SPECS

      module_function

      def write(app_dir:, dist_dir:, version:, demo_dir:, pipeline_dir:)
        app_root = app_dir.to_s
        demo_root = demo_dir.to_s
        pipeline_root = pipeline_dir.to_s
        dest = File.join(dist_dir.to_s, "assets", "source", version.to_s)
        FileUtils.mkdir_p(dest) unless File.directory?(dest)

        section_cache = {}

        PAGE_SPECS.each do |filename, specs|
          parts = [SOURCE_NOTE]
          specs.each do |label, root_kind, rel_path, cache_key|
            rendered = if cache_key
                         section_cache[cache_key] ||= render_section(label, resolve_path(root_kind, rel_path, app_root, demo_root, pipeline_root))
                       else
                         render_section(label, resolve_path(root_kind, rel_path, app_root, demo_root, pipeline_root))
                       end
            parts << rendered[0]
            body = rendered[1]
            parts << body unless body.empty?
          end

          File.write(File.join(dest, filename), parts.join)
        end
      end

      def resolve_path(root_kind, rel_path, app_root, demo_root, pipeline_root)
        case root_kind
        when :app then File.join(app_root, rel_path)
        when :demo then File.join(demo_root, rel_path)
        else File.join(pipeline_root, rel_path)
        end
      end
      private_class_method :resolve_path

      def render_section(label, path)
        raw = File.read(path)
        if raw.empty?
          empty_section = String.new(capacity: label.bytesize + 160)
          empty_section << SECTION_OPEN << label << SECTION_MID1 << "0" << SECTION_MID2 << "0" << SECTION_MID3 << SECTION_CLOSE
          return [empty_section, ""]
        end

        has_ir = raw.include?("InstantRecord")
        umask = 0
        if raw.include?("_")
          umask |= 1 if raw.include?("_only")
          umask |= 2 if raw.include?("sync_")
          umask |= 4 if raw.include?("pending_count")
          umask |= 8 if raw.include?("on_discarded_change")
        end
        mask = (has_ir ? 1 : 0) | (umask << 1)

        escaped = CGI.escapeHTML(raw)
        est_lines = raw.count("\n") + 1
        body = String.new(capacity: escaped.bytesize + est_lines * 100)
        seps = LINE_SEP

        if mask == 0
          i = 0
          if est_lines <= TABLE_LIMIT
            escaped.each_line(chomp: true) do |line|
              body << seps[i] << line
              i += 1
            end
          else
            escaped.each_line(chomp: true) do |line|
              if i < TABLE_LIMIT
                body << seps[i] << line
              else
                body << LINE_CLOSE << LINE_OPEN << (i + 1).to_s << LINE_TEXT_OPEN << line
              end
              i += 1
            end
          end
          body << LINE_END_SECTION_CLOSE
          return [build_header(label, 0, i), body]
        end

        mseps = MARKED_LINE_SEP
        marked = 0
        i = 0

        if est_lines <= TABLE_LIMIT
          if (single = SINGLE_FAMILY[mask])
            lit, re = single
            escaped.each_line(chomp: true) do |line|
              if line.include?(lit) && re.match?(line)
                marked += 1
                body << mseps[i] << line
              else
                body << seps[i] << line
              end
              i += 1
            end
          elsif has_ir && (usingle = UNDER_SINGLE[umask])
            ulit, ure = usingle
            escaped.each_line(chomp: true) do |line|
              if (line.include?("InstantRecord") && MARKER_RE_IR.match?(line)) ||
                 (line.include?(ulit) && ure.match?(line))
                marked += 1
                body << mseps[i] << line
              else
                body << seps[i] << line
              end
              i += 1
            end
          else
            has_only = (umask & 1) != 0
            has_sync = (umask & 2) != 0
            has_pend = (umask & 4) != 0
            has_disc = (umask & 8) != 0
            escaped.each_line(chomp: true) do |line|
              hit = (has_ir && line.include?("InstantRecord") && MARKER_RE_IR.match?(line)) ||
                    (line.include?("_") && (
                      (has_only && line.include?("_only") && MARKER_RE_ONLY.match?(line)) ||
                      (has_sync && line.include?("sync_") && MARKER_RE_SYNC.match?(line)) ||
                      (has_pend && line.include?("pending_count") && MARKER_RE_PEND.match?(line)) ||
                      (has_disc && line.include?("on_discarded_change") && MARKER_RE_DISC.match?(line))
                    ))
              if hit
                marked += 1
                body << mseps[i] << line
              else
                body << seps[i] << line
              end
              i += 1
            end
          end
        else
          escaped.each_line(chomp: true) do |line|
            if marker_match?(line, has_ir, umask)
              marked += 1
              if i < TABLE_LIMIT
                body << mseps[i] << line
              else
                body << LINE_CLOSE << MARKED_LINE_OPEN << (i + 1).to_s << LINE_TEXT_OPEN << line
              end
            elsif i < TABLE_LIMIT
              body << seps[i] << line
            else
              body << LINE_CLOSE << LINE_OPEN << (i + 1).to_s << LINE_TEXT_OPEN << line
            end
            i += 1
          end
        end

        body << LINE_END_SECTION_CLOSE
        [build_header(label, marked, i), body]
      end
      private_class_method :render_section

      def marker_match?(line, has_ir, umask)
        return true if has_ir && line.include?("InstantRecord") && MARKER_RE_IR.match?(line)
        return false if umask == 0 || !line.include?("_")

        ((umask & 1) != 0 && line.include?("_only") && MARKER_RE_ONLY.match?(line)) ||
          ((umask & 2) != 0 && line.include?("sync_") && MARKER_RE_SYNC.match?(line)) ||
          ((umask & 4) != 0 && line.include?("pending_count") && MARKER_RE_PEND.match?(line)) ||
          ((umask & 8) != 0 && line.include?("on_discarded_change") && MARKER_RE_DISC.match?(line))
      end
      private_class_method :marker_match?

      def build_header(label, marked, line_count)
        header = String.new(capacity: label.bytesize + 150)
        header << SECTION_OPEN << label << SECTION_MID1 <<
          (LINE_NUMS[marked] || marked.to_s) << SECTION_MID2 <<
          (LINE_NUMS[line_count] || line_count.to_s) << SECTION_MID3
      end
      private_class_method :build_header
    end
  end
end
