require "test_helper"
require "sqlite3"

class MailShellTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    InstantRecord::Change.delete_all
    MailEntry.delete_all
    Mailbox.delete_all
    @shells = Pathname(Dir.mktmpdir("mail_shells"))
    @root, MailShell.root = MailShell.root, @shells
    @mailbox = Mailbox.create!(id: "support")
    Mailbox.create!(id: "billing")
    @first = write("First request")
    @archived = write("Old request")
    act("archive", @archived)
    act("reply", @first, body: "On it")
  end

  teardown do
    MailShell.root = @root
    FileUtils.rm_rf(@shells)
  end

  def inbox_headers(member = "maya", inbox = "support")
    { "X-Instant-Record-Partition" => "mailbox_id:#{inbox}", "X-Instant-Record-Member" => member }
  end

  def write(subject, mailbox: @mailbox)
    mailbox.append!(id: SecureRandom.uuid, author: "Rae", attributes: { kind: "message", address: "rae@example.test", subject: subject, body: "Can you help?" })
  end

  def act(kind, parent, body: "")
    @mailbox.append!(id: SecureRandom.uuid, author: "maya", attributes: { kind: kind, parent_id: parent.id, body: body })
  end

  def grant(member = "maya", inbox = "support", fingerprint: MailShell.fingerprint)
    get "/email/shell", params: { fingerprint: fingerprint }, headers: inbox_headers(member, inbox)
  end

  # A browser's first load from a shell: fetch it, open it, read the stamp.
  def download(member = "maya")
    grant(member)
    assert_response :success
    get response.parsed_body.fetch("path"), headers: inbox_headers(member, "support")
    assert_response :success
    file = @shells.join("client-#{SecureRandom.hex(4)}.sqlite3")
    file.binwrite(response.body)
    database = SQLite3::Database.new(file.to_s, results_as_hash: true)
    [database, database.get_first_value("SELECT value FROM instant_record_sync_metadata WHERE key = 'cursor'").to_i]
  end

  # A wire row as the compiled runtime stores it: its datetimes in the runtime's form.
  def stored(attributes)
    attributes.merge(%w[created_at updated_at].to_h { |name| [name, Time.iso8601(attributes[name]).utc.strftime(MailShell::DB_TIME)] })
  end

  # The feed from a cursor, applied as the client applies it: an upsert by id.
  def catch_up(database, cursor)
    loop do
      get "/instant_record/events?after=#{cursor}&window=0", headers: inbox_headers
      frames = response.body.split("\n\n").reject(&:blank?)
      return cursor if frames.empty?

      frames.each do |frame|
        id = frame[/^id: (\d+)$/, 1].to_i
        event = JSON.parse(frame[/^data: (.*)$/, 1])
        row = stored(event["attributes"]).merge("server_version" => event["version"], "sync_state" => "synced")
        database.execute(%(INSERT OR REPLACE INTO mail_entries (#{row.keys.join(", ")}) VALUES (#{(["?"] * row.size).join(", ")})), row.values)
        cursor = id
      end
    end
  end

  def rows(database)
    database.execute("SELECT * FROM mail_entries ORDER BY id").map { |row| row.except("sync_state") }
  end

  def bootstrap_rows
    get "/instant_record/bootstrap", headers: inbox_headers
    response.parsed_body["records"].map { |record| stored(record["attributes"]) }.sort_by { |row| row["id"] }
  end

  test "a missing shell sends the browser to the bootstrap and is built for the next one" do
    assert_enqueued_with(job: Email::ShellBuildJob, args: ["support"]) { grant }
    assert_response :no_content

    perform_enqueued_jobs
    assert_no_enqueued_jobs { grant }
    assert_response :success
    assert_equal InstantRecord::Change.maximum(:id), response.parsed_body["cursor"]
  end

  test "a shell holds what the bootstrap sends, stamped with the cursor it was read at" do
    MailShell.build(@mailbox)
    database, cursor = download

    assert_equal InstantRecord::Change.maximum(:id), cursor
    assert_equal bootstrap_rows, rows(database)
    assert_equal ["synced"], database.execute("SELECT DISTINCT sync_state FROM mail_entries").map { |row| row["sync_state"] }
    saved = database.execute("SELECT key, value FROM instant_record_sync_metadata").to_h { |row| [row["key"], row["value"]] }
    assert_equal MailShell::MODELS.join(","), saved["compiled_models"]
    assert_equal MailShell.fingerprint, saved["shell_fingerprint"]
    tables = database.execute("SELECT name FROM sqlite_master WHERE type = 'table'").map { |row| row["name"] }
    assert_empty %w[issues messages notes channels chat_users instant_record_outbox mail_entries] - tables
  end

  test "an old shell and the feed after its stamp arrive where a fresh bootstrap does" do
    MailShell.build(@mailbox)
    stamp = MailShell.latest("support").cursor
    later = write("Arrived after the shell")
    act("reply", later, body: "Welcome")
    act("read", @first)

    database, cursor = download
    assert_equal stamp, cursor
    assert_equal InstantRecord::Change.maximum(:id), catch_up(database, cursor)
    assert_equal bootstrap_rows, rows(database)

    # Starting a change early applies it twice, and the second time changes nothing.
    catch_up(database, stamp - 1)
    assert_equal bootstrap_rows, rows(database)
  end

  test "the address is one person's, for one inbox, for a short while" do
    MailShell.build(@mailbox)
    grant("maya")
    token = URI.decode_www_form(URI(response.parsed_body.fetch("path")).query).to_h["token"]

    get "/email/shell/file", params: { token: token }, headers: inbox_headers("theo", "support")
    assert_response :not_found
    get "/email/shell/file", params: { token: token }, headers: inbox_headers("maya", "billing")
    assert_response :not_found
    get "/email/shell/file", params: { token: "forged" }, headers: inbox_headers("maya", "support")
    assert_response :not_found
    grant("jo")
    assert_response :forbidden

    travel MailShell::URL_LIFETIME + 1.second do
      get "/email/shell/file", params: { token: token }, headers: inbox_headers("maya", "support")
      assert_response :not_found
    end
  end

  test "a browser built against another schema is not offered the shell" do
    MailShell.build(@mailbox)
    assert_no_enqueued_jobs { grant(fingerprint: "0" * 64) }
    assert_response :no_content
  end

  test "a shell that is behind is still served and rebuilt, and one too far behind is not served" do
    MailShell.build(@mailbox)
    stamp = MailShell.latest("support").cursor

    InstantRecord::Change.create!(id: stamp + MailShell::REBUILD_AFTER_CHANGES + 1, record_type: "MailEntry", record_id: "r1", operation: "create", version: 1, attributes_payload: {}, partition: "mailbox_id:support")
    assert_enqueued_with(job: Email::ShellBuildJob) { grant }
    assert_response :success
    assert_equal stamp, response.parsed_body["cursor"]

    InstantRecord::Change.create!(id: stamp + MailShell::SERVE_WITHIN_CHANGES + 1, record_type: "MailEntry", record_id: "r2", operation: "create", version: 1, attributes_payload: {}, partition: "mailbox_id:support")
    grant
    assert_response :no_content

    InstantRecord::Change.where("id > ?", stamp).delete_all
    travel MailShell::REBUILD_AFTER + 1.minute do
      assert_enqueued_with(job: Email::ShellBuildJob) { grant }
      assert_response :success
    end
    travel MailShell::SERVE_WITHIN + 1.minute do
      grant
      assert_response :no_content
    end
  end

  test "the browser build computes the fingerprint from the same format and model list" do
    require "instant_record/compiler"
    manifest = InstantRecord::Compiler.manifest(root: Rails.root)
    assert_equal MailShell::FORMAT, InstantRecord::Compiler::WasmBuild::SHELL_FORMAT
    assert_equal MailShell::MODELS, manifest.synced_model_names.sort
  end

  test "a rebuild replaces the file once its addresses have run out" do
    old = MailShell.build(@mailbox)
    assert_equal old.path, MailShell.build(@mailbox).path

    write("One more")
    InstantRecord::Change.create!(id: old.cursor + MailShell::REBUILD_AFTER_CHANGES + 1, record_type: "MailEntry", record_id: "r3", operation: "create", version: 1, attributes_payload: {}, partition: "mailbox_id:support")
    travel MailShell::URL_LIFETIME + 1.second do
      fresh = MailShell.build(@mailbox)
      assert_operator fresh.cursor, :>, old.cursor
      assert_equal [fresh.path], Dir.glob(@shells.join("support.*.sqlite3").to_s)
    end
  end
end
