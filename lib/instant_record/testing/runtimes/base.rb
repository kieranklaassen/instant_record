require "json"
require "sqlite3"
require "tempfile"
require "uri"

module InstantRecord
  module Testing
    module Runtimes
      # Shared strict stderr validation, notice parsing, and direct SQLite
      # database snapshot reader used across CRuby, Wasm, and Native drivers.
      module Base
        OFFLINE_WARNING_PATTERN = /\A\[instant_record\] (?:bootstrap|drain|poll|fetch_history) failed \(offline\?\): /.freeze

        def assert_clean_stderr!(errors, context:, allow_offline_warning: false)
          lines = Array(errors).map { |line| line.to_s.strip }.reject(&:empty?)
          return if lines.empty?

          unexpected =
            if allow_offline_warning
              lines.reject { |line| OFFLINE_WARNING_PATTERN.match?(line) }
            else
              lines
            end

          return if unexpected.empty?

          raise InstantRecord::Testing::StderrError,
            "Unexpected stderr during #{context}:\n  #{unexpected.join("\n  ")}"
        end

        def parse_notice(text)
          raw = text.to_s
          return { notified: false, changes: nil } unless raw.start_with?("records_changed")

          lines = raw.split("\n")[1..].to_a.reject(&:empty?)
          return { notified: true, changes: nil } if lines.empty?

          changes = []
          unlisted = false
          lines.each do |line|
            next if line.start_with?("sync_notice:")
            next if unlisted

            if line.start_with?("{")
              parsed = JSON.parse(line)
              if parsed.is_a?(Hash) && parsed["type"] && parsed["id"]
                changes << { type: parsed["type"].to_s, id: parsed["id"].to_s }
              else
                unlisted = true
              end
            else
              at = line.index(":")
              if at && at > 0
                changes << { type: line[0...at], id: line[(at + 1)..] }
              else
                unlisted = true
              end
            end
          rescue JSON::ParserError
            unlisted = true
          end
          { notified: true, changes: (!unlisted && !changes.empty?) ? changes : nil }
        end

        def table_name_for(model_name)
          case model_name.to_s
          when "Issue" then "issues"
          when "AuthNote" then "auth_notes"
          when "Note" then "notes"
          when "Message" then "messages"
          when "Channel" then "channels"
          when "ChatUser" then "chat_users"
          when "MailEntry" then "mail_entries"
          when "AssistantChat" then "assistant_chats"
          when "AssistantTurn" then "assistant_turns"
          else
            model = InstantRecord.synced_model(model_name.to_s) || model_name.to_s.safe_constantize
            model ? model.table_name : "#{model_name.to_s.downcase}s"
          end
        end

        # Read ground-truth synced tables, sync_state, outbox count, and sync
        # metadata directly from a client's SQLite file.
        def read_sqlite_file_state(db_path, model_names:)
          db = SQLite3::Database.new(db_path, readonly: true)
          db.results_as_hash = true
          tables = {}
          sync_states = {}

          Array(model_names).each do |model_name|
            table = table_name_for(model_name)
            exists = db.get_first_value("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", [table])
            unless exists
              tables[model_name] = []
              sync_states[model_name] = []
              next
            end

            raw_rows = db.execute("SELECT * FROM \"#{table}\" ORDER BY id ASC")
            rows = raw_rows.map { |r| r.reject { |k, _| k.is_a?(Integer) } }
            tables[model_name] = InstantRecord::Testing.canonical_rows(rows)
            sync_states[model_name] = rows.map { |r| { "id" => r["id"].to_s, "sync_state" => r["sync_state"].to_s } }
          end

          pending = db.get_first_value("SELECT COUNT(*) FROM instant_record_outbox").to_i
          meta_rows = db.execute("SELECT key, value FROM instant_record_sync_metadata")
          metadata = meta_rows.each_with_object({}) { |r, acc| acc[r["key"].to_s] = r["value"] }

          {
            tables: tables,
            sync_states: sync_states,
            pending: pending,
            cursor: metadata["cursor"] ? metadata["cursor"].to_i : 0,
            bootstrapped: !metadata["cursor"].nil?,
            identity: metadata["identity"].to_s,
            metadata: metadata
          }
        ensure
          db&.close
        end

        def read_sqlite_bytes_state(bytes, model_names:)
          Tempfile.create(["ir-wasm-db", ".sqlite3"], binmode: true) do |tmp|
            tmp.write(bytes)
            tmp.flush
            read_sqlite_file_state(tmp.path, model_names: model_names)
          end
        end

        # Build an HTTP/1.1 raw request string matching AppHost#request and
        # WasmBridge/NativeBridge handle_request expectations.
        def build_http_request(method, path, body: "", content_type: "application/x-www-form-urlencoded", cookies: {})
          verb = method.to_s.upcase
          body_str = body.to_s
          if verb == "POST" && content_type.start_with?("application/x-www-form-urlencoded")
            override = URI.decode_www_form(body_str).to_h["_method"]
            verb = override.upcase if override && override.match?(/\A(?:patch|put|delete)\z/i)
          end

          cookie_header = cookies.map { |k, v| "#{k}=#{v}" }.join("; ")
          head = +"#{verb} #{path} HTTP/1.1\r\nHost: localhost\r\n"
          head << "Cookie: #{cookie_header}\r\n" unless cookie_header.empty?
          unless body_str.empty?
            head << "Content-Type: #{content_type}\r\nContent-Length: #{body_str.bytesize}\r\n"
          end
          head << "\r\n"
          head + body_str
        end

        def parse_bridge_http_response(raw, cookies: nil)
          text = raw.to_s
          split = text.index("\n\n")
          head = split ? text[0...split] : text
          body = split ? text[(split + 2)..] : ""
          lines = head.split("\n")
          status = lines.first.to_i
          status = 500 if status == 0
          headers = []
          lines[1..].to_a.each do |line|
            colon = line.index(": ")
            next unless colon

            name = line[0...colon]
            value = line[(colon + 2)..]
            if name.downcase == "set-cookie" && cookies
              pair = value.split(";").first.to_s
              eq = pair.index("=")
              if eq
                if value.match?(/max-age=0/i)
                  cookies.delete(pair[0...eq])
                else
                  cookies[pair[0...eq]] = pair[(eq + 1)..]
                end
              end
            else
              headers << [name, value]
            end
          end
          { status: status, headers: headers, body: body }
        end
      end
    end
  end
end
