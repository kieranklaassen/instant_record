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
  SUPPORT = { "member" => "maya", "inbox" => "support" }.freeze
  UNREAD = SUPPORT.merge("filter" => "unread").freeze
  BILLING = { "member" => "maya", "inbox" => "billing" }.freeze

  # compiled/pipeline/native/host.c, with this test as its driver.
  class Phone
    attr_writer :online
    attr_reader :unanswered

    # `database` is the file to boot on, or nil for a host that has not booted.
    def initialize(binary, database, session, folder: File.dirname(database))
      @session = session
      @online = true
      @unanswered = []
      @input, @output, @wait = Open3.popen2(binary, database || "-", chdir: folder)
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
    def tap(screen, params, action, args = {}, values = {}) = call("action", JSON.generate(screen: screen, params: params, action: action, args: args, values: values))
    def sync(endpoint = ENDPOINT) = call("sync", endpoint)
    def pending = call("cursor").first[/pending=(\d+)/, 1].to_i
    def cursor = call("cursor").first[/cursor=(\d+)/, 1].to_i
    def identity = call("cursor").first[/identity=(\S*)/, 1].to_s

    def boot(database) = send_path("boot", database)
    def open(database) = send_path("open", database)

    # The files the host process holds open, as the kernel lists them.
    def open_files = Dir.children("/proc/#{@wait.pid}/fd").filter_map { |fd| File.readlink("/proc/#{@wait.pid}/fd/#{fd}") rescue nil }

    # What the phone's own app does: fetch what a pass will ask for while the
    # library is free, then run the pass answering from those replies alone.
    # The block runs between the two, where a tap would.
    def prepared_sync
      plan = JSON.parse(call("sync_plan").first)
      who = identity.empty? ? "" : "&identity=#{identity}"
      wanted = []
      wanted << ["POST", "#{ENDPOINT}/mutations", plan["push"]] unless plan["push"].empty?
      wanted << ["GET", "#{ENDPOINT}/bootstrap", ""] if plan["bootstrap"]
      wanted << ["GET", "#{ENDPOINT}/events?after=#{cursor}&window=0#{who}", ""] unless plan["bootstrap"]
      @prepared = wanted.to_h { |verb, url, body| [[verb, url, body], fetch(verb, url, body)] }
      yield if block_given?
      sync
    ensure
      @prepared = nil
    end

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

    def send_path(verb, path)
      @input.write("#{verb} #{path.bytesize}\n#{path}")
      @input.flush
      reply
    end

    def exchange(request)
      line, body = request.split("\n", 2)
      verb, url = line.split(" ", 2)
      return fetch(verb, url, body) unless @prepared
      @prepared.fetch([verb, url, body.to_s]) do
        @unanswered << line
        "0\n"
      end
    end

    def fetch(verb, url, body)
      return "0\n" unless @online
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

    assert_equal JSON.parse(MailboxScreen.new(SUPPORT).json), @phone.render("mailbox", SUPPORT)
    assert_equal [@newer.id, @older.id], rows.map { |row| row["id"] }
  end

  test "a conversation opens as the server would draw it, and opening it marks it read" do
    @phone.sync
    row = rows.first

    @phone.tap(row["props"]["link"], row["params"], "open")
    @phone.tap(row["props"]["link"], row["params"], "open")
    assert_equal 1, @phone.pending
    @phone.sync

    assert_equal 0, @phone.pending
    assert MailEntry.exists?(kind: "read", parent_id: @newer.id, author: "maya")
    assert_equal JSON.parse(ThreadScreen.new(row["params"]).json), @phone.render(row["props"]["link"], row["params"])
    assert_equal JSON.parse(MailboxScreen.new(SUPPORT).json), @phone.render("mailbox", SUPPORT)
  end

  test "the menus, the unread list and mark all read are the server's, on the phone" do
    @phone.sync

    assert_equal JSON.parse(MailboxScreen.new(UNREAD).json), @phone.render("mailbox", UNREAD)
    assert_equal ["InboxSummary", @newer.id], @phone.render("mailbox", UNREAD).dig("children", 0, "children", 0, "children").map { |node| node["id"].presence || node["text"] }

    @phone.tap("mailbox", SUPPORT, "read_all")
    assert_equal ["InboxSummary", "You're all caught up"], @phone.render("mailbox", UNREAD).dig("children", 0, "children", 0, "children").map { |node| node["text"] }
    @phone.sync

    assert MailEntry.exists?(kind: "read", parent_id: @newer.id, author: "maya")
    assert_equal JSON.parse(MailboxScreen.new(SUPPORT).json), @phone.render("mailbox", SUPPORT)
  end

  test "an archive made offline shows at once and reaches the server on reconnect" do
    @phone.sync
    @phone.online = false

    @phone.tap("mailbox", SUPPORT, "archive", { "id" => @newer.id })
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
    @phone.tap("mailbox", SUPPORT, "archive", { "id" => @newer.id })
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

  test "a param keeps every character it was sent with" do
    @phone.sync

    odd = "a\nb/c \"q\" ☕"
    link = @phone.render("mailbox", SUPPORT.merge("inbox" => odd)).dig("children", 0, "children", 1, "children", 1, "children", 0, "params")

    assert_equal odd, link["inbox"]
  end

  test "input that is not an object is an error the host can read" do
    error = assert_raises(RuntimeError) { @phone.call("render", "mailbox\nmaya/support") }

    assert_predicate error.message, :present?
    assert_equal [@newer.id, @older.id], (@phone.sync && rows).map { |row| row["id"] }
  end

  test "a screen nobody wrote is an error, not an empty screen" do
    error = assert_raises(RuntimeError) { @phone.render("nowhere", SUPPORT) }

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

  test "a pass whose replies were fetched beforehand asks the network for nothing more" do
    @phone.prepared_sync
    assert_equal [@newer.id, @older.id], rows.map { |row| row["id"] }

    @phone.tap("mailbox", SUPPORT, "archive", { "id" => @newer.id })
    arrived = write("jo", "Receipt")
    @phone.prepared_sync

    assert_equal 0, @phone.pending
    assert_equal [arrived.id, @older.id], rows.map { |row| row["id"] }
    assert_equal [@older.id, arrived.id].sort, MailEntry.open_messages.where(mailbox_id: "support").pluck(:id).sort
    assert_empty @phone.unanswered
  end

  test "a reply typed on the phone keeps every character, shows at once and reaches the server" do
    @phone.sync
    thread = SUPPORT.merge("thread" => @newer.id)
    words = "On it, \"today\".\n\tThanks ☕"

    @phone.tap("thread", thread, "reply", {}, { "body" => words })
    @phone.tap("thread", thread, "reply", {}, { "body" => " \n " })

    said = @phone.render("thread", thread).dig("children", 0, "children").find { |node| node["kind"] == "props" }["children"].last
    assert_includes said["children"].map { |prop| prop["text"] }, words
    assert_equal 1, @phone.pending
    @phone.sync
    assert_equal [words], MailEntry.where(kind: "reply", parent_id: @newer.id, author: "maya").pluck(:body)
    assert_equal JSON.parse(ThreadScreen.new(thread).json), @phone.render("thread", thread)
  end

  test "older mail arrives a page at a time, and the phone says whether more is left" do
    (MailEntry::PAGE_SIZE + 8).times { |n| travel_to((n + 10).minutes.ago) { write("rae", "Bulk #{n}") } }
    @phone.sync
    list = -> { @phone.render("mailbox", SUPPORT).dig("children", 0, "children", 0, "children") }
    summary = -> { list.call.first["children"].to_h { |prop| [prop["props"]["name"], prop["text"]] } }
    more = list.call.last

    assert_equal ["more", "older:support"], more.values_at("kind", "id")
    assert_equal MailEntry::PAGE_SIZE, rows.size
    assert_equal "true", summary.call["more"]

    get "/email/sync/maya/support/records?#{more["props"]["query"]}"
    assert_response :success
    @phone.call("history", JSON.generate(key: more["id"], response: response.body))

    assert_equal MailEntry::PAGE_SIZE + 10, rows.size
    assert_equal ["row", "false"], [list.call.last["kind"], summary.call["more"]]
    assert_equal MailEntry.open_messages.where(mailbox_id: "support").order(created_at: :desc, id: :desc).pluck(:id), rows.map { |row| row["id"] }
  end

  test "a tap made while a pass was fetching is not lost, and goes out with the next pass" do
    @phone.sync
    @phone.tap("mailbox", SUPPORT, "archive", { "id" => @older.id })

    @phone.prepared_sync { @phone.tap("thread", SUPPORT.merge("thread" => @newer.id), "open") }

    assert_equal ["POST #{ENDPOINT}/mutations"], @phone.unanswered
    assert_equal 2, @phone.pending
    assert_equal [@newer.id], rows.map { |row| row["id"] }

    @phone.prepared_sync

    assert_equal 0, @phone.pending
    assert_equal 1, MailEntry.where(kind: "archive", parent_id: @older.id).count
    assert_equal 1, MailEntry.where(kind: "read", parent_id: @newer.id, author: "maya").count
  end

  test "another inbox opens in its own file, and the first is closed" do
    billing = File.join(@folder, "billing.sqlite3")
    Mailbox.find("billing").append!(id: SecureRandom.uuid, author: "jo", attributes: { kind: "message", address: "jo@example.test", subject: "Receipt", body: "Paid" })
    @phone.sync
    @phone.online = false
    @phone.tap("mailbox", SUPPORT, "archive", { "id" => @newer.id })

    @phone.open(billing)
    assert_equal 0, @phone.pending
    assert_empty @phone.render("mailbox", BILLING).dig("children", 0, "children", 0, "children").select { |node| node["kind"] == "row" }
    if File.directory?("/proc/self/fd")
      assert_empty @phone.open_files.grep(/inbox\.sqlite3/), "the first database is still open"
      assert_not_empty @phone.open_files.grep(/billing\.sqlite3/)
    end
    @phone.online = true
    @phone.sync(ENDPOINT.sub("maya/support", "maya/billing"))
    assert_equal ["Receipt"], @phone.render("mailbox", BILLING).dig("children", 0, "children", 0, "children").select { |node| node["kind"] == "row" }.map { |row| row["children"][1]["text"] }
    assert_empty rows, "billing's file holds support's mail"

    @phone.open(File.join(@folder, "inbox.sqlite3"))
    assert_equal 1, @phone.pending
    assert_equal [@older.id], rows.map { |row| row["id"] }
    @phone.sync
    assert_equal 0, @phone.pending
    assert_equal [@older.id], MailEntry.open_messages.where(mailbox_id: "support").pluck(:id)
  end

  test "the feedback screen hands the app's own form who is writing" do
    form = @phone.render("feedback", SUPPORT).dig("children", 0, "children", 0)

    assert_equal ["swift", "FeedbackForm"], form.values_at("kind", "text")
    assert_equal [%w[from maya], %w[inbox support]], form["children"].map { |prop| [prop.dig("props", "name"), prop["text"]] }
  end

  test "a file that will not open leaves the app in the one it had" do
    @phone.sync
    held = rows.map { |row| row["id"] }
    assert_not_empty held

    assert_raises(RuntimeError) { @phone.open(File.join(@folder, "no-such-folder", "other.sqlite3")) }
    assert_equal held, rows.map { |row| row["id"] }
    @phone.tap("mailbox", SUPPORT, "archive", { "id" => @newer.id })
    @phone.sync
    assert_equal [@older.id], MailEntry.open_messages.where(mailbox_id: "support").pluck(:id)
  end

  test "the app boots once, and nothing runs before it has" do
    again = assert_raises(RuntimeError) { @phone.boot(File.join(@folder, "second.sqlite3")) }
    assert_match "boots once", again.message
    assert_equal [], rows

    asleep = Phone.new(@binary, nil, self, folder: @folder)
    early = assert_raises(RuntimeError) { asleep.render("mailbox", SUPPORT) }
    assert_match "ir_boot first", early.message
    assert_raises(RuntimeError) { asleep.open(File.join(@folder, "third.sqlite3")) }
    asleep.boot(File.join(@folder, "third.sqlite3"))
    assert_equal "screen", asleep.render("mailbox", SUPPORT)["kind"]
  ensure
    asleep&.close
  end

  test "an archive the server rejects is undone on the phone" do
    @phone.sync
    MailEntry.where(id: @newer.id).delete_all

    @phone.tap("mailbox", SUPPORT, "archive", { "id" => @newer.id })
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
    @phone.render("mailbox", SUPPORT).dig("children", 0, "children", 0, "children").select { |node| node["kind"] == "row" }
  end
end
