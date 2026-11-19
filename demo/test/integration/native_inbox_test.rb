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

    def render(screen, arg) = JSON.parse(call("render", "#{screen}\n#{arg}").first)
    def tap(screen, arg, action, on) = call("action", [screen, arg, action, on].join("\n"))
    def sync = call("sync", ENDPOINT)
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

    assert_equal JSON.parse(MailboxScreen.new("maya/support").json), @phone.render("mailbox", "maya/support")
    assert_equal [@newer.id, @older.id], rows.map { |row| row["id"] }
  end

  test "a conversation opens as the server would draw it, and opening it marks it read" do
    @phone.sync
    row = rows.first

    @phone.tap("mailbox", "maya/support", row["action"], row["arg"])
    assert_equal 1, @phone.pending
    @phone.sync

    assert_equal 0, @phone.pending
    assert MailEntry.exists?(kind: "read", parent_id: @newer.id, author: "maya")
    assert_equal JSON.parse(ThreadScreen.new(row["arg"]).json), @phone.render(row["props"]["link"], row["arg"])
    assert_equal JSON.parse(MailboxScreen.new("maya/support").json), @phone.render("mailbox", "maya/support")
  end

  test "the menus, the unread list and mark all read are the server's, on the phone" do
    @phone.sync

    assert_equal JSON.parse(MailboxScreen.new("maya/support/unread").json), @phone.render("mailbox", "maya/support/unread")
    assert_equal ["InboxSummary", @newer.id], @phone.render("mailbox", "maya/support/unread").dig("children", 0, "children", 0, "children").map { |node| node["id"].presence || node["text"] }

    @phone.tap("mailbox", "maya/support", "read_all", "maya/support")
    assert_equal %w[swift], @phone.render("mailbox", "maya/support/unread").dig("children", 0, "children", 0, "children").map { |node| node["kind"] }
    @phone.sync

    assert MailEntry.exists?(kind: "read", parent_id: @newer.id, author: "maya")
    assert_equal JSON.parse(MailboxScreen.new("maya/support").json), @phone.render("mailbox", "maya/support")
  end

  test "an archive made offline shows at once and reaches the server on reconnect" do
    @phone.sync
    @phone.online = false

    @phone.tap("mailbox", "maya/support", "archive", "maya/support/#{@newer.id}")
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
    @phone.tap("mailbox", "maya/support", "archive", "maya/support/#{@newer.id}")
    @phone.close

    @phone = Phone.new(@binary, File.join(@folder, "inbox.sqlite3"), self)
    @phone.online = false

    assert_equal [@older.id], rows.map { |row| row["id"] }
    assert_equal 1, @phone.pending
    assert_empty Dir.children(@folder).reject { |name| name.start_with?("inbox.sqlite3") }, "the app wrote outside its database"
  end

  test "a sync pass alone brings a change from elsewhere" do
    @phone.sync
    arrived = write("jo", "Receipt")

    @phone.sync

    assert_equal [arrived.id, @newer.id, @older.id], rows.map { |row| row["id"] }
  end

  test "a screen nobody wrote is an error, not an empty screen" do
    error = assert_raises(RuntimeError) { @phone.render("nowhere", "maya/support") }

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

    @phone.tap("mailbox", "maya/support", "archive", "maya/support/#{@newer.id}")
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

  def rows
    @phone.render("mailbox", "maya/support").dig("children", 0, "children", 0, "children").select { |node| node["kind"] == "row" }
  end
end
