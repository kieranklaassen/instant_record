require "cgi"
require "json"
require "rack"
require "securerandom"
require "tmpdir"
require "uri"

module InstantRecord
  module Testing
    # Authoritative sync server backing dual-runtime parity checks and multi-client
    # chaos traces. Supports two modes behind one identical interface:
    #
    # 1. RackServer: dispatches real HTTP requests through a mounted Rails app
    #    (CRuby + PostgreSQL) with full session/cookie identity management.
    # 2. StandaloneServer: self-contained ActiveRecord server (PostgreSQL via
    #    DATABASE_URL when set, or isolated SQLite otherwise) exercising the gem's
    #    real MutationApplier, SyncScope, Change, and AppliedMutation classes.
    module AuthoritativeServer
      def self.build(rails_app: nil, database_url: nil, models: %w[Issue AuthNote])
        if rails_app
          RackServer.new(app: rails_app, model_names: models)
        else
          StandaloneServer.new(database_url: database_url, model_names: models)
        end
      end

      # Shared helpers for querying visible rows, advancing cursors to 32-bit
      # boundaries, and performing server-originated writes.
      module SharedOperations
        attr_reader :model_names

        def backend_label
          adapter = ActiveRecord::Base.connection_db_config.adapter
          "CRuby+#{adapter}"
        end

        def models
          @model_names.filter_map { |name| InstantRecord.synced_model(name) || name.safe_constantize }
        end

        def model_for(name)
          InstantRecord.synced_model(name.to_s) || name.to_s.safe_constantize ||
            raise(ArgumentError, "Unknown synced model: #{name}")
        end

        def current_cursor
          InstantRecord::Change.maximum(:id) || 0
        end

        # Advance instant_record_changes.id sequence so subsequent changes emit
        # cursors right at wasm32 signed 32-bit boundaries (e.g. 2_147_483_645).
        def set_cursor_floor(cursor_value)
          target = Integer(cursor_value)
          conn = ActiveRecord::Base.connection
          adapter = conn.adapter_name.downcase
          if adapter.include?("postgres")
            seq = conn.select_value("SELECT pg_get_serial_sequence('instant_record_changes', 'id')")
            value, used = target <= 0 ? [1, false] : [target, true]
            conn.execute("SELECT setval(#{conn.quote(seq)}, #{value}, #{used})") if seq
          elsif adapter.include?("sqlite")
            if conn.select_value("SELECT name FROM sqlite_master WHERE type='table' AND name='sqlite_sequence'")
              updated = conn.update("UPDATE sqlite_sequence SET seq = #{target} WHERE name = 'instant_record_changes'")
              conn.execute("INSERT INTO sqlite_sequence (name, seq) VALUES ('instant_record_changes', #{target})") if updated == 0
            end
          end
          target
        end

        # Insert a synthetic change row directly at a specific cursor id (e.g. INT32_MAX)
        # along with updating the underlying record's server_version, so compiled clients
        # are tested directly against boundary integer values on the wire.
        def seed_boundary_record(model_name: "Issue", id: nil, title: "int32 boundary", server_version: INT32_MAX, cursor_id: nil, updated_at: nil)
          model = model_for(model_name)
          record_id = id || SecureRandom.uuid
          stamp = updated_at || Time.now.utc

          InstantRecord.applying_client_mutation do
            record = model.find_or_initialize_by(id: record_id)
            attrs = { "title" => title, "updated_at" => stamp }
            attrs["state"] = "open" if model.column_names.include?("state") && record.new_record?
            attrs["created_at"] = stamp if record.new_record?
            record.assign_attributes(attrs.slice(*model.column_names))
            record.server_version = server_version
            record.sync_state = "synced"
            record.save!(validate: false)

            change_attrs = {
              record_type: model.name,
              record_id: record.id,
              operation: record.previously_new_record? ? "create" : "update",
              version: server_version,
              attributes_payload: InstantRecord.wire_attributes(record.attributes),
              scope: InstantRecord.scope_of(record)
            }
            change_attrs[:id] = Integer(cursor_id) if cursor_id
            change = InstantRecord::Change.create!(change_attrs)
            { record: record, change: change }
          end
        end

        # Authoritative server-originated write (simulates a background job or server request).
        def server_write(model_name:, operation:, id: nil, attributes: {}, clock_offset: 0)
          model = model_for(model_name)
          stamp = Time.now.utc + clock_offset.to_f
          case operation.to_s
          when "create"
            attrs = attributes.transform_keys(&:to_s)
            attrs["id"] = id if id
            attrs["created_at"] ||= stamp
            attrs["updated_at"] ||= stamp
            model.create!(attrs.slice(*model.column_names))
          when "update"
            model.find_by(id: id)&.tap do |record|
              attrs = attributes.transform_keys(&:to_s).merge("updated_at" => stamp)
              record.update!(attrs.slice(*model.column_names))
            end
          when "destroy"
            model.find_by(id: id)&.tap(&:destroy!)
          else
            raise ArgumentError, "Unknown server_write operation: #{operation}"
          end
        end

        def visible_state(identity: nil)
          asker = identity_object(identity)
          models.each_with_object({}) do |model, state|
            rows = InstantRecord::SyncScope.visible(model, asker).order(:id).map(&:attributes)
            state[model.name] = InstantRecord::Testing.canonical_rows(rows)
          end
        end

        def reset_data!
          models.each(&:delete_all)
          InstantRecord::Change.delete_all
          InstantRecord::AppliedMutation.delete_all
          InstantRecord::OutboxMutation.delete_all if ActiveRecord::Base.connection.data_source_exists?("instant_record_outbox")
          InstantRecord::SyncMetadata.delete_all if ActiveRecord::Base.connection.data_source_exists?("instant_record_sync_metadata")
          set_cursor_floor(0)
        end
      end

      # Drives a live mounted Rails application (CRuby + PostgreSQL) via Rack.
      class RackServer
        include SharedOperations

        APP_PATHS = %w[/todo /auth /notes /slack /email /up].freeze
        private_constant :APP_PATHS

        def initialize(app:, model_names: %w[Issue AuthNote])
          @app = app
          @model_names = Array(model_names)
          @cookies_by_identity = {}
          @mount_path = (app.config.instant_record.mount_path || InstantRecord::DEFAULT_MOUNT_PATH).to_s.sub(%r{/+\z}, "")
        end

        def close
          nil
        end

        def identity_object(person_id)
          if defined?(::DemoAsker)
            ::DemoAsker.new(nil, person_id)
          else
            person_id
          end
        end

        def reset_data!
          @cookies_by_identity.clear
          super
        end

        # Dispatch an HTTP request against the mounted Rails app. If `identity`
        # is provided, ensures a signed Rails session cookie for that person via
        # the app's auth session endpoint (when present) so real `SyncScope.identity`
        # reads the real Rails session cookie.
        def exchange(method, url, body = "", identity: nil, content_type: nil)
          uri = URI.parse(url.to_s)
          path = uri.path.to_s
          path = "#{@mount_path}#{path}" unless path.start_with?(@mount_path, *APP_PATHS)
          path_with_query = uri.query.to_s.empty? ? path : "#{path}?#{uri.query}"

          cookie = cookie_for_identity(identity)
          verb = method.to_s.upcase
          content_type ||=
            if verb == "POST" && body.to_s.lstrip.start_with?("{", "[")
              "application/json"
            else
              "application/x-www-form-urlencoded"
            end

          env = Rack::MockRequest.env_for(
            path_with_query,
            method: verb,
            input: body.to_s,
            "CONTENT_TYPE" => content_type,
            "HTTP_HOST" => "localhost",
            "HTTP_COOKIE" => cookie.to_s
          )
          status, headers, response_body = @app.call(env)
          chunks = +""
          begin
            response_body.each { |part| chunks << part.to_s }
          ensure
            response_body.close if response_body.respond_to?(:close)
          end

          { status: status.to_i, headers: headers, body: chunks }
        end

        private

        def cookie_for_identity(person_id)
          return "" if person_id.nil? || person_id.to_s.empty?
          return @cookies_by_identity[person_id] if @cookies_by_identity.key?(person_id)

          # Establish a real Rails session cookie via the JSON auth session endpoint.
          env = Rack::MockRequest.env_for(
            "/auth/session",
            method: "POST",
            input: JSON.generate(person: person_id),
            "CONTENT_TYPE" => "application/json",
            "HTTP_HOST" => "localhost"
          )
          status, headers, body = @app.call(env)
          begin
            raise InstantRecord::Testing::Error, "POST /auth/session failed for #{person_id.inspect}: status=#{status}" unless status.to_i == 200

            set_cookie = headers["set-cookie"] || headers["Set-Cookie"]
            pair = Array(set_cookie).flat_map { |line| line.to_s.split("\n") }.map { |c| c.split(";").first }.join("; ")
            @cookies_by_identity[person_id] = pair
          ensure
            body.close if body.respond_to?(:close)
          end
        end
      end

      # Lightweight standalone ActiveRecord server (Postgres via DATABASE_URL or
      # isolated SQLite) that mirrors the exact demo schema, models, SyncScope,
      # and Engine controller wire contracts without requiring a Rails boot.
      class StandaloneServer
        include SharedOperations

        DemoPerson = Struct.new(:person_id) do
          def to_s = ""
          def sync_identity_key = person_id || "anonymous"
          def sync_reset_types = ["AuthNote"]
        end

        ROLE_BY_PERSON = { "ada" => "admin", "ben" => "member", "cleo" => "member" }.freeze

        attr_reader :db_path

        def initialize(database_url: nil, model_names: %w[Issue AuthNote])
          @model_names = Array(model_names)
          @database_url = database_url && !database_url.to_s.empty? ? database_url.to_s : nil
          @tmpdir = @database_url ? nil : Dir.mktmpdir("instant-record-server")
          @db_path = @tmpdir ? File.join(@tmpdir, "server.sqlite3") : nil
          @shard = :"ir_standalone_server_#{object_id}"
          @previous_synced = InstantRecord.synced_models.dup
          @previous_scope_from = InstantRecord.config.scope_from
          @closed = false

          completed = false
          begin
            setup_database!
            ensure_models!
            InstantRecord.sync(*models)
            completed = true
          ensure
            unless completed
              begin
                close
              rescue StandardError
                nil
              end
            end
          end
        end

        def close
          return if @closed

          @closed = true
          begin
            InstantRecord.sync(*@previous_synced)
          ensure
            begin
              InstantRecord.config.scope_from = @previous_scope_from
            ensure
              begin
                if defined?(ActiveRecord::Base)
                  ActiveRecord::Base.connection_handler.remove_connection_pool(
                    ActiveRecord::Base.name,
                    role: :writing,
                    shard: @shard
                  )
                end
              ensure
                FileUtils.remove_entry(@tmpdir) if @tmpdir && Dir.exist?(@tmpdir)
              end
            end
          end
        end

        def backend_label = with_server_shard { super }
        def current_cursor = with_server_shard { super }
        def set_cursor_floor(cursor_value) = with_server_shard { super }
        def seed_boundary_record(**kwargs) = with_server_shard { super }
        def server_write(**kwargs) = with_server_shard { super }
        def visible_state(identity: nil) = with_server_shard { super }
        def reset_data! = with_server_shard { super }

        def identity_object(person_id)
          known = ROLE_BY_PERSON.key?(person_id.to_s) ? person_id.to_s : nil
          DemoPerson.new(known)
        end

        def exchange(method, url, body = "", identity: nil, content_type: nil)
          with_server_shard do
            uri = URI.parse(url.to_s)
            path = uri.path.to_s
            params = URI.decode_www_form(uri.query.to_s).to_h
            verb = method.to_s.upcase
            asker = identity_object(identity)

            case "#{verb} #{path}"
            when %r{\AGET .*/bootstrap\z} then handle_bootstrap(asker)
            when %r{\APOST .*/mutations\z} then handle_mutations(body, asker)
            when %r{\AGET .*/events\z} then handle_events(params, asker)
            when %r{\AGET .*/records\z} then handle_records(params, asker)
            when %r{\AGET .*/todo\z} then handle_todo_index
            when %r{\APOST .*/todo/issues\z} then handle_todo_create(body)
            when %r{\APATCH .*/todo/issues/([^/]+)\z} then handle_todo_update($1, body)
            when %r{\ADELETE .*/todo/issues/([^/]+)\z} then handle_todo_destroy($1)
            else respond(404, "Not Found: #{verb} #{path}")
            end
          end
        end

        private

        def with_server_shard(&block)
          ActiveRecord::Base.connected_to(role: :writing, shard: @shard, &block)
        end

        def setup_database!
          require "active_record"
          require "active_support/core_ext/time"
          Time.zone ||= "UTC"

          gem_root = InstantRecord::Testing.gem_root.to_s
          require File.join(gem_root, "app/models/instant_record/change")
          require File.join(gem_root, "app/models/instant_record/applied_mutation")
          require File.join(gem_root, "app/models/instant_record/mutation_applier")
          require "instant_record/sync_scope"

          config = @database_url || { adapter: "sqlite3", database: @db_path }
          ActiveRecord::Base.connection_handler.establish_connection(
            config,
            owner_name: ActiveRecord::Base.name,
            role: :writing,
            shard: @shard
          )

          migrations_dir = File.join(gem_root, "db/migrate")
          with_server_shard do
            ActiveRecord::Migration.suppress_messages do
              ActiveRecord::MigrationContext.new(migrations_dir).migrate
              ActiveRecord::Schema.define do
                unless data_source_exists?(:issues)
                  create_table :issues, id: :string do |t|
                    t.string :title, null: false
                    t.string :state, null: false, default: "open"
                    t.integer :server_version, null: false, default: 0
                    t.string :sync_state, null: false, default: "synced"
                    t.timestamps
                  end
                end

                unless data_source_exists?(:auth_notes)
                  create_table :auth_notes, id: :string do |t|
                    t.string :title, null: false
                    t.text :body, null: false, default: ""
                    t.string :audience, null: false, default: "owner"
                    t.string :owner_id, null: false
                    t.integer :server_version, null: false, default: 0
                    t.string :sync_state, null: false, default: "synced"
                    t.timestamps
                  end
                end
              end
            end
          end
        end

        def ensure_models!
          unless Object.const_defined?(:Issue, false)
            Object.const_set(:Issue, Class.new(ActiveRecord::Base) do
              self.table_name = "issues"
              include InstantRecord::Syncable
              validates :title, presence: true, length: { maximum: 200 }
              validates :title, exclusion: { in: ["reject me"], message: "is not allowed by the server" }, unless: -> { InstantRecord.browser? }
            end)
          end

          unless Object.const_defined?(:AuthNote, false)
            roles = ROLE_BY_PERSON
            Object.const_set(:AuthNote, Class.new(ActiveRecord::Base) do
              self.table_name = "auth_notes"
              include InstantRecord::Syncable

              const_set(:AUDIENCES, %w[everyone members admins owner].freeze)
              validates :title, presence: true, length: { maximum: 120 }
              validates :body, length: { maximum: 2_000 }
              validates :audience, inclusion: { in: const_get(:AUDIENCES) }
              validates :owner_id, presence: true

              syncable_to do |asker|
                person = asker&.person_id
                if person.nil?
                  where(audience: "everyone")
                elsif roles[person] == "admin"
                  where(audience: %w[everyone members admins]).or(where(owner_id: person))
                else
                  where(audience: %w[everyone members]).or(where(owner_id: person))
                end
              end

              writable_by do |asker|
                asker&.person_id ? where(owner_id: asker.person_id) : none
              end
            end)
          end
        end

        def handle_bootstrap(asker)
          payload = ActiveRecord::Base.transaction do
            cursor = InstantRecord::Change.maximum(:id) || 0
            records = models.flat_map do |model|
              visible = InstantRecord::SyncScope.visible(model, asker)
              window = model.instant_record_sync_window
              rows = window ? window.in_window(visible) : visible
              InstantRecord.record_payloads(rows)
            end
            {
              cursor: cursor,
              records: records,
              identity: InstantRecord::SyncScope.key(asker),
              server_time: InstantRecord::HLC.iso_now
            }
          end
          respond_json(payload)
        end

        def handle_mutations(body, asker)
          parsed = JSON.parse(body.to_s)
          stale = InstantRecord::SyncScope.stale?(parsed["identity"], asker) ? InstantRecord::SyncScope.reset_types(asker) : []
          results = Array(parsed["mutations"]).map do |raw|
            mutation = {
              id: raw["id"],
              record_type: raw["record_type"],
              record_id: raw["record_id"],
              operation: raw["operation"],
              base_version: raw["base_version"],
              hlc: raw["hlc"],
              changes: raw["changes"] || {}
            }
            if stale.include?(mutation[:record_type])
              { mutation_id: mutation[:id], status: "rejected", reason: "identity changed" }
            else
              InstantRecord::MutationApplier.apply(mutation, asker)
            end
          end
          respond_json(results: results, server_time: InstantRecord::HLC.iso_now)
        end

        def handle_events(params, asker)
          cursor = (params["after"] || 0).to_i
          if InstantRecord::SyncScope.stale?(params["identity"], asker)
            reset = JSON.generate(InstantRecord::SyncScope.reset_event(asker))
            return respond(200, "event: reset\ndata: #{reset}\n\n", type: "text/event-stream")
          end

          changes = InstantRecord::Change.poll(cursor, scope: InstantRecord::SyncScope.token(asker))
          sse = +""
          InstantRecord::SyncScope.events_for(changes, asker).each do |id, event|
            sse << "id: #{id}\nevent: change\ndata: #{JSON.generate(event)}\n\n"
          end
          respond(200, sse, type: "text/event-stream")
        end

        def handle_records(params, asker)
          model = InstantRecord.synced_model(params["type"])
          return respond(404) unless model

          window = model.instant_record_sync_window
          return respond(422) unless window

          before_at = Time.zone.parse(params["before_created_at"].to_s)
          return respond(400) if before_at.nil? || params["before_id"].to_s.empty?

          limit = (params["limit"].to_i > 0 ? params["limit"].to_i : window.limit).clamp(1, 200)
          rows = window.keyset_below(at: before_at, id: params["before_id"], partition: params["partition"])
            .merge(InstantRecord::SyncScope.visible(model, asker))
            .limit(limit + 1)
            .to_a

          payload = {
            records: InstantRecord.record_payloads(rows.first(limit)),
            has_more: rows.size > limit
          }
          respond_json(payload)
        end

        def handle_todo_index
          issues = model_for("Issue").order(created_at: :desc)
          html = issues.map { |i| %(<li data-id="#{CGI.escapeHTML(i.id.to_s)}" class="#{i.state}">#{CGI.escapeHTML(i.title.to_s)}</li>) }.join("\n")
          respond(200, %(<ul class="issues">#{html}</ul>), type: "text/html")
        end

        def handle_todo_create(body)
          fields = URI.decode_www_form(body.to_s).to_h
          title = fields["issue[title]"] || fields["title"]
          model_for("Issue").create!(title: title)
          redirect_to_todo
        end

        def handle_todo_update(id, body)
          fields = URI.decode_www_form(body.to_s).to_h
          issue = model_for("Issue").find(id)
          issue.update!(state: fields["done"] == "1" ? "done" : "open")
          redirect_to_todo
        end

        def handle_todo_destroy(id)
          model_for("Issue").find(id).destroy!
          redirect_to_todo
        end

        def respond(status, body = "", type: nil)
          { status: status, headers: type ? { "content-type" => type } : {}, body: body }
        end

        def respond_json(payload) = respond(200, JSON.generate(payload), type: "application/json")

        def redirect_to_todo = { status: 302, headers: { "location" => "/todo" }, body: "" }
      end
    end
  end
end
