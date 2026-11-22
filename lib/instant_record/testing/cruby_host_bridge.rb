# Persistent headless CRuby client bridge speaking synchronous NDJSON over
# stdin/stdout (identical wire protocol to wasm_host_bridge.mjs). Runs all
# simulated CRuby clients in an isolated SQLite-only ActiveRecord process so
# they never share StatementCache, InstantRecord.browser?, or Client state
# with a PostgreSQL-backed authoritative Rails server.
#
# Usage: ruby -Ilib cruby_host_bridge.rb <tmpdir>
require "active_record"
require "active_support/core_ext/time"
require "cgi"
require "json"
require "stringio"
require "uri"
require "instant_record"

Time.zone = "UTC"

# This process is exclusively a local-first client runtime.
InstantRecord.define_singleton_method(:browser?) { true }

tmpdir = ARGV[0] || raise("usage: cruby_host_bridge.rb <tmpdir>")

# Bootstrap default connection so ActiveRecord::Base has a live SQLite pool.
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: File.join(tmpdir, "_bootstrap.sqlite3"))

class Issue < ActiveRecord::Base
  self.table_name = "issues"
  include InstantRecord::Syncable
  validates :title, presence: true, length: { maximum: 200 }
end

class AuthNote < ActiveRecord::Base
  self.table_name = "auth_notes"
  include InstantRecord::Syncable
  AUDIENCES = %w[everyone members admins owner].freeze
  validates :title, presence: true, length: { maximum: 120 }
  validates :body, length: { maximum: 2_000 }
  validates :audience, inclusion: { in: AUDIENCES }
  validates :owner_id, presence: true
end

InstantRecord.sync(Issue, AuthNote)

$stdout.sync = true
$stdin.sync = true

def write_msg(obj)
  $stdout.puts(JSON.generate(obj))
  $stdout.flush
end

def read_msg
  line = $stdin.gets
  return nil unless line

  JSON.parse(line)
end

class PipeTransport
  attr_reader :exchanges

  def initialize(client_id)
    @client_id = client_id
    @exchanges = []
  end

  def get_json(path)
    JSON.parse(exchange("GET", path, ""))
  rescue JSON::ParserError => e
    raise InstantRecord::Client::Transport::Error, "GET #{path} invalid JSON: #{e.message}"
  end

  def post_json(path, payload)
    JSON.parse(exchange("POST", path, JSON.generate(payload)))
  rescue JSON::ParserError => e
    raise InstantRecord::Client::Transport::Error, "POST #{path} invalid JSON: #{e.message}"
  end

  def each_event(path, &block)
    parser = InstantRecord::Client::Transport::SseParser.new(&block)
    parser.feed(exchange("GET", path, ""))
  end

  private

  def exchange(method, path, body)
    url = "#{InstantRecord.config.endpoint}#{path}"
    write_msg({ type: "exchange", client: @client_id, method: method, url: url, body: body })
    reply = read_msg
    raise InstantRecord::Client::Transport::Error, "EOF waiting for exchange reply" unless reply

    status = reply["status"].to_i
    @exchanges << "#{method} #{url} -> #{status}"
    unless status >= 200 && status < 300
      raise InstantRecord::Client::Transport::Error, "#{method} #{path} -> #{status}"
    end
    reply["body"].to_s
  end
end

class RecordingNotifier
  attr_reader :last_notice

  def initialize
    @last_notice = ""
  end

  def records_changed
    @last_notice = InstantRecord::Client.changes_notice
  end
end

ClientState = Struct.new(:id, :db_path, :shard, :stream_parser, :stream_events, :history_marks, keyword_init: true)

clients = {}
counter = 0

def init_schema!(shard)
  ActiveRecord::Base.connected_to(role: :writing, shard: shard) do
    ActiveRecord::Migration.suppress_messages do
      ActiveRecord::Schema.define do
        create_table :instant_record_outbox, id: :string, force: true do |t|
          t.string :record_type, null: false
          t.string :record_id, null: false
          t.string :operation, null: false
          t.text :changes_payload
          t.integer :base_version, null: false, default: 0
          t.timestamps
        end

        create_table :instant_record_sync_metadata, id: false, force: true do |t|
          t.string :key, null: false, primary_key: true
          t.string :value
          t.timestamps
        end

        create_table :issues, id: :string, force: true do |t|
          t.string :title, null: false
          t.string :state, null: false, default: "open"
          t.integer :server_version, null: false, default: 0
          t.string :sync_state, null: false, default: "synced"
          t.timestamps
        end

        create_table :auth_notes, id: :string, force: true do |t|
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

def with_client(client, transport: nil, notifier: nil, endpoint: nil)
  InstantRecord::Client.transport = transport if transport
  InstantRecord::Client.notifier = notifier if notifier
  InstantRecord.config.endpoint = endpoint if endpoint && !endpoint.to_s.empty?
  InstantRecord::Client.streaming = false
  InstantRecord::Client.instance_variable_set(:@stream_parser, client.stream_parser)
  InstantRecord::Client.instance_variable_set(:@stream_events, client.stream_events)
  InstantRecord::Client.instance_variable_set(:@history_marks, client.history_marks)
  InstantRecord::Client.instance_variable_set(:@changed_records, [])
  InstantRecord::Client.instance_variable_set(:@unlisted_changes, false)

  captured = StringIO.new
  prev_stderr = $stderr
  $stderr = captured

  val = ActiveRecord::Base.connected_to(role: :writing, shard: client.shard) { yield }

  client.stream_parser = InstantRecord::Client.instance_variable_get(:@stream_parser)
  client.stream_events = InstantRecord::Client.instance_variable_get(:@stream_events)
  client.history_marks = InstantRecord::Client.instance_variable_get(:@history_marks)
  [val, captured.string.lines(chomp: true)]
ensure
  $stderr = prev_stderr if prev_stderr
end

def model_class(name)
  case name.to_s
  when "Issue" then Issue
  when "AuthNote" then AuthNote
  else raise ArgumentError, "Unknown model: #{name}"
  end
end

write_msg({ type: "ready" })

while (cmd = read_msg)
  begin
    case cmd["op"]
    when "create_client"
      counter += 1
      cid = cmd["client"].to_s
      db_path = File.join(tmpdir, "#{cid.gsub(/[^a-zA-Z0-9_-]/, '_')}_#{counter}.sqlite3")
      shard = :"client_#{counter}"
      ActiveRecord::Base.connection_handler.establish_connection(
        { adapter: "sqlite3", database: db_path },
        owner_name: ActiveRecord::Base.name,
        role: :writing,
        shard: shard
      )
      init_schema!(shard)
      clients[cid] = ClientState.new(
        id: cid,
        db_path: db_path,
        shard: shard,
        stream_parser: nil,
        stream_events: [],
        history_marks: {}
      )
      write_msg({ type: "result", ok: true, db_path: db_path, errors: [] })

    when "request"
      client = clients.fetch(cmd["client"].to_s)
      verb = cmd["method"].to_s.upcase
      body_str = cmd["body"].to_s
      content_type = cmd["contentType"].to_s
      if verb == "POST" && content_type.start_with?("application/x-www-form-urlencoded")
        override = URI.decode_www_form(body_str).to_h["_method"]
        verb = override.upcase if override && override.match?(/\A(?:patch|put|delete)\z/i)
      end
      route = URI.parse(cmd["path"].to_s).path
      params = URI.decode_www_form(body_str).to_h

      res, errors = with_client(client) do
        if verb == "GET" && route == "/todo"
          issues = Issue.order(created_at: :desc)
          html = issues.map { |i| %(<li data-id="#{CGI.escapeHTML(i.id.to_s)}" class="#{i.state}">#{CGI.escapeHTML(i.title.to_s)}</li>) }.join("\n")
          { status: 200, headers: [["Content-Type", "text/html"]], body: "<ul class=\"issues\">#{html}</ul>" }
        elsif verb == "POST" && route == "/todo/issues"
          Issue.create!(title: params["issue[title]"] || params["title"])
          { status: 302, headers: [["Location", "/todo"]], body: "" }
        elsif verb == "PATCH" && route =~ %r{\A/todo/issues/([^/]+)\z}
          Issue.find(Regexp.last_match(1)).update!(state: params["done"] == "1" ? "done" : "open")
          { status: 302, headers: [["Location", "/todo"]], body: "" }
        elsif verb == "DELETE" && route =~ %r{\A/todo/issues/([^/]+)\z}
          Issue.find(Regexp.last_match(1)).destroy!
          { status: 302, headers: [["Location", "/todo"]], body: "" }
        elsif verb == "GET" && route == "/auth"
          notes = AuthNote.order(created_at: :desc)
          html = notes.map { |n| %(<article data-id="#{CGI.escapeHTML(n.id.to_s)}">#{CGI.escapeHTML(n.title.to_s)}</article>) }.join("\n")
          { status: 200, headers: [["Content-Type", "text/html"]], body: "<section class=\"auth-notes\">#{html}</section>" }
        elsif verb == "POST" && route == "/auth/notes"
          note = AuthNote.new(
            title: params["note[title]"],
            body: params["note[body]"].to_s,
            audience: params["note[audience]"] || "owner",
            owner_id: params["note[owner_id]"].to_s
          )
          note.save
          { status: 302, headers: [["Location", "/auth"]], body: "" }
        elsif verb == "DELETE" && route =~ %r{\A/auth/notes/([^/]+)\z}
          AuthNote.find_by(id: Regexp.last_match(1))&.destroy!
          { status: 302, headers: [["Location", "/auth"]], body: "" }
        else
          { status: 404, headers: [], body: "Not Found" }
        end
      end
      write_msg({ type: "result", **res, exit: 0, errors: errors })

    when "sync"
      client = clients.fetch(cmd["client"].to_s)
      transport = PipeTransport.new(client.id)
      notifier = RecordingNotifier.new
      res, errors = with_client(client, transport: transport, notifier: notifier, endpoint: cmd["endpoint"]) do
        changed = InstantRecord::Client.sync_pass
        {
          changed: changed,
          pending: InstantRecord::Client.pending_count,
          cursor: InstantRecord::Client.cursor,
          notice: notifier.last_notice,
          exchanges: transport.exchanges
        }
      end
      write_msg({ type: "result", **res, exit: 0, errors: errors })

    when "sync_plan"
      client = clients.fetch(cmd["client"].to_s)
      plan, errors = with_client(client) do
        mutations = InstantRecord::Client.pending_mutations
        push = mutations.empty? ? "" : JSON.generate(InstantRecord::Client.mutations_payload(mutations))
        { "push" => push, "bootstrap" => !InstantRecord::Client.bootstrapped? }
      end
      write_msg({ type: "result", plan: plan, errors: errors })

    when "consume_stream"
      client = clients.fetch(cmd["client"].to_s)
      notifier = RecordingNotifier.new
      res, errors = with_client(client, notifier: notifier) do
        applied = InstantRecord::Client.consume_stream(cmd["chunk"].to_s)
        {
          applied: applied,
          cursor: InstantRecord::Client.cursor,
          bootstrapped: InstantRecord::Client.bootstrapped?,
          notice: notifier.last_notice
        }
      end
      write_msg({ type: "result", **res, exit: 0, errors: errors })

    when "sync_state"
      client = clients.fetch(cmd["client"].to_s)
      res, errors = with_client(client) do
        {
          bootstrapped: InstantRecord::Client.bootstrapped?,
          cursor: InstantRecord::Client.cursor,
          pending: InstantRecord::Client.pending_count,
          identity: InstantRecord::Client.identity_key.to_s
        }
      end
      write_msg({ type: "result", **res, errors: errors })

    when "history"
      client = clients.fetch(cmd["client"].to_s)
      res, errors = with_client(client) do
        meta_key = "history:#{cmd['key']}"
        response = cmd["response"].to_s
        if response.empty?
          mark = InstantRecord::SyncMetadata.get(meta_key)
          { "ok" => !mark.nil?, "applied" => 0, "has_more" => mark == "more" }
        else
          page = JSON.parse(response)
          records = Array(page["records"])
          more = page["has_more"] == true
          InstantRecord::OutboxMutation.transaction do
            records.each { |rec| InstantRecord::Client.apply_change(rec) }
            InstantRecord::SyncMetadata.set(meta_key, more ? "more" : "end")
          end
          { "ok" => true, "applied" => records.size, "has_more" => more }
        end
      end
      write_msg({ type: "result", history: res, errors: errors })

    when "local_write"
      client = clients.fetch(cmd["client"].to_s)
      skew = cmd["clockSkew"].to_f
      stamp = Time.now.utc + skew
      attrs = (cmd["attributes"] || {}).transform_keys(&:to_s)
      record_id, errors = with_client(client) do
        klass = model_class(cmd["model"])
        case cmd["operation"].to_s
        when "create"
          attrs["id"] = cmd["id"] if cmd["id"]
          attrs["created_at"] ||= stamp if skew != 0.0
          attrs["updated_at"] ||= stamp if skew != 0.0
          klass.create!(attrs.slice(*klass.column_names)).id
        when "update"
          rec = klass.find_by(id: cmd["id"])
          if rec
            attrs["updated_at"] ||= stamp if skew != 0.0
            rec.update!(attrs.slice(*klass.column_names))
            rec.id
          end
        when "destroy"
          rec = klass.find_by(id: cmd["id"])
          if rec
            rec.destroy!
            rec.id
          end
        else
          raise ArgumentError, "Unknown local_write operation: #{cmd['operation']}"
        end
      end
      write_msg({ type: "result", record_id: record_id, errors: errors })

    when "shutdown"
      write_msg({ type: "result", ok: true })
      break
    else
      write_msg({ type: "error", message: "Unknown op: #{cmd['op']}" })
    end
  rescue StandardError => e
    write_msg({ type: "error", message: "#{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}" })
  end
end
