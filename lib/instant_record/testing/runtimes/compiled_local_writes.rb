require "uri"

module InstantRecord
  module Testing
    module Runtimes
      # A compiled client has no write API of its own: its local writes go
      # through the demo app's HTML forms.
      module CompiledLocalWrites
        def execute_local_write(client, model:, operation:, id:, attributes:)
          attrs = attributes.transform_keys(&:to_s)
          case [model.to_s, operation.to_s]
          when ["Issue", "create"]
            submit_form(client, "POST", "/todo/issues", "issue[title]" => attrs["title"])
            newest_id_from_snapshot(client, "Issue", title: attrs["title"])
          when ["Issue", "update"]
            submit_form(client, "PATCH", "/todo/issues/#{id}", "done" => attrs["state"].to_s == "done" ? "1" : "0")
            id
          when ["Issue", "destroy"]
            submit_form(client, "DELETE", "/todo/issues/#{id}")
            id
          when ["AuthNote", "create"]
            submit_form(client, "POST", "/auth/notes",
              "note[title]" => attrs["title"],
              "note[body]" => attrs["body"].to_s,
              "note[audience]" => attrs["audience"] || "owner",
              "note[owner_id]" => attrs["owner_id"].to_s)
            newest_id_from_snapshot(client, "AuthNote", title: attrs["title"])
          when ["AuthNote", "destroy"]
            submit_form(client, "DELETE", "/auth/notes/#{id}")
            id
          else
            raise ArgumentError, "Unsupported #{local_write_kind} local_write: #{model}##{operation}"
          end
        end

        private

        def submit_form(client, verb, path, fields = {})
          fields = { "_method" => verb.downcase, **fields } unless verb == "POST"
          res = execute_request(client, "POST", path, body: URI.encode_www_form(fields), content_type: "application/x-www-form-urlencoded")
          raise Error, "Expected 200/302 on #{verb} #{path}, got #{res[:status]}" unless [200, 302, 303].include?(res[:status])
        end

        def newest_id_from_snapshot(client, model_name, title:)
          rows = client.snapshot_state(model_names: [model_name])[:tables][model_name]
          rows.select { |r| r["title"] == title }.max_by { |r| r["created_at"].to_s }&.fetch("id")
        end
      end
    end
  end
end
