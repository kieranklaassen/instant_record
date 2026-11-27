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

  def get_json(path) = exchange_json("GET", path)
  def post_json(path, payload) = exchange_json("POST", path, payload)

  def each_event(path, &block)
    parser = InstantRecord::Client::Transport::SseParser.new(&block)
    parser.feed(exchange("GET", path, ""))
  end

  private

  def exchange_json(method, path, payload = nil)
    JSON.parse(exchange(method, path, payload ? JSON.generate(payload) : ""))
  rescue JSON::ParserError => e
    raise InstantRecord::Client::Transport::Error, "#{method} #{path} invalid JSON: #{e.message}"
  end

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

# What InstantRecord::Client keeps in memory for one client between commands.
CARRIED_STATE = %i[stream_parser stream_events].freeze
ClientState = Struct.new(:id, :shard, *CARRIED_STATE, keyword_init: true)

MIGRATIONS_DIR = File.expand_path("../../../db/migrate", __dir__)

def init_schema!(shard)
  ActiveRecord::Base.connected_to(role: :writing, shard: shard) do
    ActiveRecord::Migration.suppress_messages do
      ActiveRecord::MigrationContext.new(MIGRATIONS_DIR).migrate
      ActiveRecord::Schema.define do
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

def create_client(id, shard, db_path)
  ActiveRecord::Base.connection_handler.establish_connection(
    { adapter: "sqlite3", database: db_path },
    owner_name: ActiveRecord::Base.name,
    role: :writing,
    shard: shard
  )
  init_schema!(shard)
  ClientState.new(id: id, shard: shard, stream_events: [])
end

# Runs the block as the given client and sends the fields it returns as the
# reply, with whatever the block wrote to stderr.
def reply_as(client, transport: nil, notifier: nil, endpoint: nil)
  InstantRecord::Client.transport = transport if transport
  InstantRecord::Client.notifier = notifier if notifier
  InstantRecord.config.endpoint = endpoint if endpoint && !endpoint.to_s.empty?
  InstantRecord::Client.streaming = false
  CARRIED_STATE.each { |name| InstantRecord::Client.instance_variable_set(:"@#{name}", client[name]) }
  InstantRecord::Client.instance_variable_set(:@changed_records, [])
  InstantRecord::Client.instance_variable_set(:@unlisted_changes, false)

  captured = StringIO.new
  prev_stderr = $stderr
  $stderr = captured

  fields = ActiveRecord::Base.connected_to(role: :writing, shard: client.shard) { yield }

  CARRIED_STATE.each { |name| client[name] = InstantRecord::Client.instance_variable_get(:"@#{name}") }
  $stderr = prev_stderr
  write_msg({ type: "result", **fields, errors: captured.string.lines(chomp: true) })
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

def html_page(body)
  { status: 200, headers: [["Content-Type", "text/html"]], body: body, exit: 0 }
end

def redirect_to(path)
  { status: 302, headers: [["Location", path]], body: "", exit: 0 }
end

def handle_request(client, cmd)
  verb = cmd["method"].to_s.upcase
  body_str = cmd["body"].to_s
  if verb == "POST" && cmd["contentType"].to_s.start_with?("application/x-www-form-urlencoded")
    override = URI.decode_www_form(body_str).to_h["_method"]
    verb = override.upcase if override && override.match?(/\A(?:patch|put|delete)\z/i)
  end
  route = URI.parse(cmd["path"].to_s).path
  params = URI.decode_www_form(body_str).to_h

  reply_as(client) do
    case "#{verb} #{route}"
    when "GET /todo"
      issues = Issue.order(created_at: :desc)
      html = issues.map { |i| %(<li data-id="#{CGI.escapeHTML(i.id.to_s)}" class="#{i.state}">#{CGI.escapeHTML(i.title.to_s)}</li>) }.join("\n")
      html_page("<ul class=\"issues\">#{html}</ul>")
    when "POST /todo/issues"
      Issue.create!(title: params["issue[title]"] || params["title"])
      redirect_to("/todo")
    when %r{\APATCH /todo/issues/([^/]+)\z}
      Issue.find($1).update!(state: params["done"] == "1" ? "done" : "open")
      redirect_to("/todo")
    when %r{\ADELETE /todo/issues/([^/]+)\z}
      Issue.find($1).destroy!
      redirect_to("/todo")
    when "GET /auth"
      notes = AuthNote.order(created_at: :desc)
      html = notes.map { |n| %(<article data-id="#{CGI.escapeHTML(n.id.to_s)}">#{CGI.escapeHTML(n.title.to_s)}</article>) }.join("\n")
      html_page("<section class=\"auth-notes\">#{html}</section>")
    when "POST /auth/notes"
      AuthNote.new(
        title: params["note[title]"],
        body: params["note[body]"].to_s,
        audience: params["note[audience]"] || "owner",
        owner_id: params["note[owner_id]"].to_s
      ).save
      redirect_to("/auth")
    when %r{\ADELETE /auth/notes/([^/]+)\z}
      AuthNote.find_by(id: $1)&.destroy!
      redirect_to("/auth")
    else
      { status: 404, headers: [], body: "Not Found", exit: 0 }
    end
  end
end

def handle_sync(client, cmd)
  transport = PipeTransport.new(client.id)
  notifier = RecordingNotifier.new
  reply_as(client, transport: transport, notifier: notifier, endpoint: cmd["endpoint"]) do
    {
      changed: InstantRecord::Client.sync_pass,
      pending: InstantRecord::Client.pending_count,
      cursor: InstantRecord::Client.cursor,
      notice: notifier.last_notice,
      exchanges: transport.exchanges,
      exit: 0
    }
  end
end

def handle_sync_plan(client)
  reply_as(client) do
    mutations = InstantRecord::Client.pending_mutations
    push = mutations.empty? ? "" : JSON.generate(InstantRecord::Client.mutations_payload(mutations))
    { plan: { "push" => push, "bootstrap" => !InstantRecord::Client.bootstrapped? } }
  end
end

def handle_consume_stream(client, cmd)
  notifier = RecordingNotifier.new
  reply_as(client, notifier: notifier) do
    {
      applied: InstantRecord::Client.consume_stream(cmd["chunk"].to_s),
      cursor: InstantRecord::Client.cursor,
      bootstrapped: InstantRecord::Client.bootstrapped?,
      notice: notifier.last_notice,
      exit: 0
    }
  end
end

def handle_sync_state(client)
  reply_as(client) do
    {
      bootstrapped: InstantRecord::Client.bootstrapped?,
      cursor: InstantRecord::Client.cursor,
      pending: InstantRecord::Client.pending_count,
      identity: InstantRecord::Client.identity_key.to_s
    }
  end
end

def handle_history(client, cmd)
  reply_as(client) do
    meta_key = "history:#{cmd['key']}"
    response = cmd["response"].to_s
    if response.empty?
      mark = InstantRecord::SyncMetadata.get(meta_key)
      { history: { "ok" => !mark.nil?, "applied" => 0, "has_more" => mark == "more" } }
    else
      page = JSON.parse(response)
      records = Array(page["records"])
      more = page["has_more"] == true
      InstantRecord::OutboxMutation.transaction do
        records.each { |rec| InstantRecord::Client.apply_change(rec) }
        InstantRecord::SyncMetadata.set(meta_key, more ? "more" : "end")
      end
      { history: { "ok" => true, "applied" => records.size, "has_more" => more } }
    end
  end
end

def handle_local_write(client, cmd)
  skew = cmd["clockSkew"].to_f
  stamp = Time.now.utc + skew
  attrs = (cmd["attributes"] || {}).transform_keys(&:to_s)
  attrs["updated_at"] ||= stamp if skew != 0.0
  reply_as(client) do
    InstantRecord::HLC.with_clock(-> { Time.now.utc + skew }) do
      klass = model_class(cmd["model"])
      record =
        case cmd["operation"].to_s
        when "create"
          attrs["id"] = cmd["id"] if cmd["id"]
          attrs["created_at"] ||= stamp if skew != 0.0
          klass.create!(attrs.slice(*klass.column_names))
        when "update"
          klass.find_by(id: cmd["id"])&.tap { |found| found.update!(attrs.slice(*klass.column_names)) }
        when "destroy"
          klass.find_by(id: cmd["id"])&.tap(&:destroy!)
        else
          raise ArgumentError, "Unknown local_write operation: #{cmd['operation']}"
        end
      { record_id: record&.id }
    end
  end
end

clients = {}
counter = 0
client_for = ->(cmd) { clients.fetch(cmd["client"].to_s) }

write_msg({ type: "ready" })

while (cmd = read_msg)
  begin
    case cmd["op"]
    when "create_client"
      counter += 1
      cid = cmd["client"].to_s
      db_path = File.join(tmpdir, "#{cid.gsub(/[^a-zA-Z0-9_-]/, '_')}_#{counter}.sqlite3")
      clients[cid] = create_client(cid, :"client_#{counter}", db_path)
      write_msg({ type: "result", ok: true, db_path: db_path, errors: [] })
    when "request"        then handle_request(client_for.(cmd), cmd)
    when "sync"           then handle_sync(client_for.(cmd), cmd)
    when "sync_plan"      then handle_sync_plan(client_for.(cmd))
    when "consume_stream" then handle_consume_stream(client_for.(cmd), cmd)
    when "sync_state"     then handle_sync_state(client_for.(cmd))
    when "history"        then handle_history(client_for.(cmd), cmd)
    when "local_write"    then handle_local_write(client_for.(cmd), cmd)
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
