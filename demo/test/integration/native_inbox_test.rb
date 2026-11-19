require "test_helper"
require "open3"
require "tmpdir"

# The Inbox as the phone runs it: the demo compiled to a native library, its
# screens included, against a SQLite file. This test stands where the phone's
# renderer and its network would be. It asks the library for screens, sends it
# taps, and answers its sync requests from this Rails app.
#
#   python3 compiled/pipeline/build_native.py
#   INSTANT_RECORD_NATIVE_HOST=../compiled/.build-native/host bin/rails test test/integration/native_inbox_test.rb
class NativeInboxTest < ActionDispatch::IntegrationTest
  ENDPOINT = "http://www.example.com/email/sync/maya/support"
  MAYA = { "member" => "maya", "inbox" => "support" }.freeze

  # compiled/pipeline/native/host.c, with this test as its driver.
  class Phone
    attr_writer :online

    def initialize(binary, database, session)
      @session = session
      @online = true
      @input, @output, @wait = Open3.popen2(binary, database, chdir: File.dirname(database))
      @input.binmode
      @output.binmode
      reply
    end

    def call(entry, input = "")
      @input.write("call #{entry} #{input.bytesize}\n#{input}")
      @input.flush
      reply
    end

    def render(screen, params) = JSON.parse(call("render", JSON.generate(screen: screen, params: params)).first)
    def tap(screen, params, action, with = {}) = call("action", JSON.generate(screen: screen, params: params, action: action, with: with))
    def open(database) = call("open", database)
    def sync(endpoint = ENDPOINT) = call("sync", endpoint)
    def pending = call("cursor").first[/pending=(\d+)/, 1].to_i
    def cursor = call("cursor").first[/cursor=(\d+)/, 1].to_i

    def close
      @input.close
      @wait.value
    end

    private

    def reply
      loop do
        head = @output.gets.to_s.split
        case head.first
        when "ok"
          return [@output.read(head[1].to_i), @output.read(head[2].to_i)].map { |text| text.force_encoding(Encoding::UTF_8) }
        when "exchange"
          answer = exchange(@output.read(head[1].to_i))
          @input.write("#{answer.bytesize}\n#{answer}")
          @input.flush
        when "error" then raise @output.read(head[1].to_i)
        else raise "The native host stopped: #{head.inspect}"
        end
      end
    end

    def exchange(request)
      return "0\n" unless @online
      line, body = request.split("\n", 2)
      verb, url = line.split(" ", 2)
      path = URI(url).request_uri
      if verb == "GET"
        @session.get path
      else
        @session.post path, params: body, headers: { "CONTENT_TYPE" => "application/json" }
      end
      "#{@session.response.status}\n#{@session.response.body}"
    end
  end

  setup do
    @binary = ENV["INSTANT_RECORD_NATIVE_HOST"]&.then { |path| File.expand_path(path) }
    skip "Build the native host (compiled/pipeline/build_native.py) and set INSTANT_RECORD_NATIVE_HOST to run this." unless @binary && File.executable?(@binary)
    MailEntry.delete_all
    Mailbox.delete_all
    @support = Mailbox.create!(id: "support")
    Mailbox.create!(id: "billing")
    travel_to(2.minutes.ago) { @older = write("rae", "Night shift") }
    @newer = write("sam", "October invoice")
    @support.append!(id: SecureRandom.uuid, author: "maya", attributes: { kind: "read", parent_id: @older.id })
    @folder = Dir.mktmpdir
    @phone = Phone.new(@binary, File.join(@folder, "inbox.sqlite3"), self)
  end

  teardown do
    @phone&.close
    FileUtils.remove_entry(@folder) if @folder
  end

  test "the phone draws the mailbox this server would draw" do
    assert_empty rows

    @phone.sync

    assert_equal JSON.parse(MailboxScreen.new(MAYA).json), @phone.render("mailbox", MAYA)
    assert_equal [@newer.id, @older.id], rows.map { |row| row["id"] }
  end

  test "a conversation opens as the server would draw it, and opening it marks it read" do
    @phone.sync
    row = rows.first

    @phone.tap(row["props"]["link"], row["params"], "open")
    assert_equal 1, @phone.pending
    @phone.tap(row["props"]["link"], row["params"], "open")
    assert_equal 1, @phone.pending
    @phone.sync

    assert_equal 0, @phone.pending
    assert MailEntry.exists?(kind: "read", parent_id: @newer.id, author: "maya")
    assert_equal JSON.parse(ThreadScreen.new(row["params"]).json), @phone.render("thread", row["params"])
    assert_equal JSON.parse(MailboxScreen.new(MAYA).json), @phone.render("mailbox", MAYA)
  end

  test "the menus, the unread list and mark read are the server's, on the phone" do
    @phone.sync
    unread = MAYA.merge("show" => "unread")

    assert_equal JSON.parse(MailboxScreen.new(unread).json), @phone.render("mailbox", unread)
    assert_equal [@newer.id], rows(unread).map { |row| row["id"] }

    @phone.tap("mailbox", MAYA, "read_all")
    assert_empty rows(unread)
    @phone.sync

    assert MailEntry.exists?(kind: "read", parent_id: @newer.id, author: "maya")
    assert_equal JSON.parse(MailboxScreen.new(MAYA).json), @phone.render("mailbox", MAYA)
  end

  test "a value reaches the screen as it was sent, whatever it holds" do
    odd = @support.append!(id: "unread", author: "rae", attributes: { kind: "message", address: "rae@example.test", subject: "Odd id", body: "Hello" })
    @phone.sync
    words = "She said \"yes\"\nsee you / at the café ☕"

    @phone.tap("thread", MAYA.merge("id" => odd.id), "reply", { "body" => words })
    @phone.sync

    assert_equal words, MailEntry.find_by(kind: "reply", parent_id: "unread").body
    assert_equal [odd.id, @newer.id, @older.id], rows.map { |row| row["id"] }
    assert_equal JSON.parse(ThreadScreen.new(MAYA.merge("id" => odd.id)).json), @phone.render("thread", MAYA.merge("id" => odd.id))
  end

  test "input that is not JSON is an error the host can read, and the next call works" do
    @phone.sync

    error = assert_raises(RuntimeError) { @phone.call("render", "mailbox\nmaya/support") }

    assert_match(/JSON|unexpected|parse/i, error.message)
    assert_equal [@newer.id, @older.id], rows.map { |row| row["id"] }
  end

  test "a reply made with no connection shows at once and reaches the server on reconnect" do
    @phone.sync
    @phone.online = false
    there = MAYA.merge("id" => @newer.id)

    @phone.tap("thread", there, "reply", { "body" => "On it." })
    @phone.tap("thread", there, "reply", { "body" => "   " })
    @phone.sync

    assert_equal 1, @phone.pending
    assert_equal ["Hello \"there\"\ncafé", "On it."], bodies(@phone.render("thread", there))
    assert_not MailEntry.exists?(kind: "reply")

    @phone.online = true
    @phone.sync

    assert_equal 0, @phone.pending
    assert_equal "On it.", MailEntry.find_by(kind: "reply", parent_id: @newer.id, author: "maya").body
  end

  test "an archive made offline shows at once and reaches the server on reconnect" do
    @phone.sync
    @phone.online = false

    @phone.tap("mailbox", MAYA, "archive", { "id" => @newer.id })
    @phone.sync

    assert_equal [@older.id], rows.map { |row| row["id"] }
    assert_equal 1, @phone.pending
    assert_equal 2, MailEntry.open_messages.where(mailbox_id: "support").count

    @phone.online = true
    @phone.sync

    assert_equal 0, @phone.pending
    assert_equal [@older.id], MailEntry.open_messages.where(mailbox_id: "support").pluck(:id)
  end

  test "mail and a queued write survive the app being closed, with no network" do
    @phone.sync
    @phone.online = false
    @phone.tap("mailbox", MAYA, "archive", { "id" => @newer.id })
    @phone.close

    @phone = Phone.new(@binary, File.join(@folder, "inbox.sqlite3"), self)
    @phone.online = false

    assert_equal [@older.id], rows.map { |row| row["id"] }
    assert_equal 1, @phone.pending
    assert_empty Dir.children(@folder).reject { |name| name.start_with?("inbox.sqlite3") }, "the app wrote outside its database"
  end

  test "another inbox is another database, opened without starting the app again" do
    billing = { "member" => "maya", "inbox" => "billing" }
    receipt = Mailbox.find("billing").append!(id: SecureRandom.uuid, author: "jo",
      attributes: { kind: "message", address: "jo@example.test", subject: "Receipt", body: "Hello" })
    @phone.sync
    @phone.online = false
    @phone.tap("mailbox", MAYA, "archive", { "id" => @newer.id })
    @phone.online = true
    first, second = File.join(@folder, "inbox.sqlite3"), File.join(@folder, "billing.sqlite3")

    3.times do
      @phone.open(second)
      assert_empty rows, "the first inbox's mail is in the second database"
      assert_equal 0, @phone.pending
      @phone.sync(ENDPOINT.sub("support", "billing"))
      assert_equal [receipt.id], rows(billing).map { |row| row["id"] }

      @phone.open(first)
      assert_equal [@older.id], rows.map { |row| row["id"] }
      assert_equal 1, @phone.pending
    end

    @phone.sync
    assert_equal 0, @phone.pending
    assert_equal [@older.id], MailEntry.open_messages.where(mailbox_id: "support").pluck(:id)
  end

  test "a database that cannot be opened is an error, and the one that was open stays open" do
    @phone.sync

    assert_raises(RuntimeError) { @phone.open(File.join(@folder, "missing-folder", "x.sqlite3")) }

    assert_equal [@newer.id, @older.id], rows.map { |row| row["id"] }, "the database that was open is no longer"
  end

  test "older mail loads a page at a time until the beginning, and the screen says when it is there" do
    120.times { |n| travel_to(1.day.ago + n.seconds) { write("rae", "Old #{n}") } }
    @phone.sync

    assert_equal MailEntry::PAGE_SIZE, rows.size
    assert_equal ["true", "Load older mail"], [summary("more"), list.last["text"]]

    @phone.online = false
    @phone.tap("mailbox", MAYA, "older")
    assert_equal MailEntry::PAGE_SIZE, rows.size
    @phone.online = true

    newest = rows.first(3).map { |row| row["id"] }
    @phone.tap("mailbox", MAYA, "older")
    assert_equal MailEntry::PAGE_SIZE * 2, rows.size
    assert_equal newest, rows.first(3).map { |row| row["id"] }
    assert_equal "true", summary("more")

    @phone.tap("mailbox", MAYA, "older")
    assert_equal 122, rows.size
    assert_equal MailEntry.open_messages.where(mailbox_id: "support").order(created_at: :desc, id: :desc).pluck(:id), rows.map { |row| row["id"] }
    assert_equal ["false", "row"], [summary("more"), list.last["kind"]]
    assert_equal "Mark 121 read", @phone.render("mailbox", MAYA).dig("children", 0, "children", 1, "children", 1, "children", 2, "text")
  end

  test "archiving a message does not hide that the server has older mail" do
    60.times { |n| travel_to(1.day.ago + n.seconds) { write("rae", "Old #{n}") } }
    @phone.sync

    @phone.tap("mailbox", MAYA, "archive", { "id" => rows.last["id"] })

    assert_equal MailEntry::PAGE_SIZE - 1, rows.size
    assert_equal ["true", "Load older mail"], [summary("more"), list.last["text"]]
  end

  test "a sync pass alone brings a change from elsewhere" do
    @phone.sync
    arrived = write("jo", "Receipt")

    @phone.sync

    assert_equal [arrived.id, @newer.id, @older.id], rows.map { |row| row["id"] }
  end

  test "a screen nobody wrote is an error, not an empty screen" do
    error = assert_raises(RuntimeError) { @phone.render("nowhere", MAYA) }

    assert_match "No screen named nowhere", error.message
    assert_equal [@newer.id, @older.id], (@phone.sync && rows).map { |row| row["id"] }
  end

  test "a change from elsewhere arrives over the feed and names what changed" do
    @phone.sync
    arrived = write("jo", "Receipt")
    get "/email/sync/maya/support/events?after=#{@phone.cursor}"

    _out, notice = @phone.call("stream", response.body)

    assert_equal "records_changed\nMailEntry:#{arrived.id}", notice
    assert_equal [arrived.id, @newer.id, @older.id], rows.map { |row| row["id"] }
  end

  test "an archive the server rejects is undone on the phone" do
    @phone.sync
    MailEntry.where(id: @newer.id).delete_all

    @phone.tap("mailbox", MAYA, "archive", { "id" => @newer.id })
    assert_equal [@older.id], rows.map { |row| row["id"] }
    @phone.sync

    assert_equal 0, @phone.pending
    assert_equal [@newer.id, @older.id], rows.map { |row| row["id"] }
  end

  private

  def write(author, subject)
    @support.append!(id: SecureRandom.uuid, author: author,
      attributes: { kind: "message", address: "#{author}@example.test", subject: subject, body: "Hello \"there\"\ncafé" })
  end

  def list(params = MAYA)
    @phone.render("mailbox", params).dig("children", 0, "children", 0, "children")
  end

  def rows(params = MAYA) = list(params).select { |node| node["kind"] == "row" }

  def summary(name) = list.first["children"].find { |node| node["id"] == name }["text"]

  def bodies(thread)
    thread.dig("children", 0, "children").find { |node| node["kind"] == "props" }["children"].map { |record| record["children"].find { |node| node["id"] == "body" }["text"] }
  end
end
