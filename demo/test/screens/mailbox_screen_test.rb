require "test_helper"

class MailboxScreenTest < ActiveSupport::TestCase
  MAYA = { "member" => "maya", "inbox" => "support" }.freeze
  THEO = { "member" => "theo", "inbox" => "support" }.freeze
  UNREAD = MAYA.merge("show" => "unread").freeze

  setup do
    MailEntry.delete_all
    Mailbox.delete_all
    @support = Mailbox.create!(id: "support")
    Mailbox.create!(id: "billing")
    travel_to(2.minutes.ago) { @older = write("support", "rae", "Night shift") }
    @newer = write("support", "sam", "October invoice")
    write("billing", "jo", "Receipt")
  end

  test "lists one inbox's open mail newest first, each row opening its conversation" do
    rows = rows_for(MAYA)

    assert_equal [@newer.id, @older.id], rows.map(&:id)
    assert_equal %w[thread thread], rows.map { |row| row.props["link"] }
    assert_equal MAYA.merge("id" => @newer.id), rows.first.params
    assert_equal "", rows.first.action
    assert_includes texts(rows.first), "October invoice"
  end

  test "a row says where its date sits and how many lines its text may take" do
    row = rows_for(MAYA).first

    assert_equal %w[image text spacer date], row.children.first.children.map(&:kind)
    assert_equal %w[1 2], row.children.select { |node| node.kind == "text" }.map { |node| node.props["lines"] }
  end

  test "leaves out archived mail" do
    @support.append!(id: SecureRandom.uuid, author: "theo", attributes: { kind: "archive", parent_id: @newer.id })

    assert_equal [@older.id], rows_for(MAYA).map(&:id)
  end

  test "marks mail this member has not read, and not mail they wrote" do
    mine = write("support", "maya", "From me")

    unread = rows_for(MAYA).select { |row| kinds(row).include?("image") }.map(&:id)

    assert_equal [@newer.id, @older.id], unread
    assert_not_includes unread, mine.id
  end

  test "archiving takes the message off the list for everyone in the inbox" do
    MailboxScreen.new(MAYA).perform("archive", { "id" => @newer.id })

    assert_equal [@older.id], rows_for(MAYA).map(&:id)
    assert_equal [@older.id], rows_for(THEO).map(&:id)
  end

  test "an action on another inbox's mail, or by someone outside the inbox, does nothing" do
    assert_no_difference -> { MailEntry.count } do
      MailboxScreen.new("member" => "maya", "inbox" => "billing").perform("archive", { "id" => @newer.id })
      MailboxScreen.new("member" => "jo", "inbox" => "support").perform("archive", { "id" => @newer.id })
      MailboxScreen.new(MAYA).perform("archive", { "id" => "missing" })
      MailboxScreen.new(MAYA).perform("archive", {})
    end
    assert_empty rows_for("member" => "jo", "inbox" => "support")
  end

  test "a message whose id is a word the screen uses is still a message" do
    odd = @support.append!(id: "unread", author: "rae", attributes: { kind: "message", address: "rae@example.test", subject: "Odd id", body: "Hello" })

    assert_equal MAYA.merge("id" => "unread"), rows_for(MAYA).find { |row| row.id == odd.id }.params
    MailboxScreen.new(MAYA).perform("archive", { "id" => "unread" })

    assert_equal [@newer.id, @older.id], rows_for(MAYA).map(&:id)
  end

  test "the leading menu lists the member's inboxes, each opening in place of this one, with this one selected" do
    menu = toolbar(MAYA).first

    assert_equal %w[leading person], [menu.props["position"], menu.props["image"]]
    assert_equal %w[Support Billing], menu.children.map(&:text)
    assert_equal %w[mailbox mailbox], menu.children.map { |item| item.props["link"] }
    assert_equal [MAYA, { "member" => "maya", "inbox" => "billing" }], menu.children.map(&:params)
    assert_equal ["true", nil], menu.children.map { |item| item.props["selected"] }
    assert_equal [nil, "true"], toolbar("member" => "maya", "inbox" => "billing").first.children.map { |item| item.props["selected"] }
    assert_equal %w[Support], toolbar(THEO).first.children.map(&:text)
  end

  test "the trailing menu chooses all mail or unread mail, and the choice is a param of the screen" do
    all, unread, mark = toolbar(MAYA).last.children

    assert_equal %w[trailing filter], toolbar(MAYA).last.props.values_at("position", "image")
    assert_equal [["All", MAYA, "true"], ["Unread", UNREAD, nil]], [all, unread].map { |item| [item.text, item.params, item.props["selected"]] }
    assert_equal ["Mark 2 read", "read_all"], [mark.text, mark.action]
    assert_equal [nil, "true"], toolbar(UNREAD).last.children.first(2).map { |item| item.props["selected"] }
  end

  test "unread only lists what this member has not read" do
    ThreadScreen.new(MAYA.merge("id" => @newer.id)).perform("open", {})

    assert_equal [@older.id], rows_for(UNREAD).map(&:id)
    assert_equal [@newer.id, @older.id], rows_for(MAYA).map(&:id)
  end

  test "mark read names how many it marks, marks them for this member alone, and then is gone" do
    assert_difference -> { MailEntry.where(kind: "read", author: "maya").count }, 2 do
      MailboxScreen.new(MAYA).perform("read_all", {})
      MailboxScreen.new(MAYA).perform("read_all", {})
    end
    assert_empty rows_for(UNREAD)
    assert_equal %w[All Unread], toolbar(MAYA).last.children.map(&:text)
    assert_equal 2, rows_for(THEO.merge("show" => "unread")).size
    assert_no_difference -> { MailEntry.count } do
      MailboxScreen.new("member" => "jo", "inbox" => "support").perform("read_all", {})
    end
  end

  test "a Swift view heads the list with what the inbox holds for this member" do
    summary = list(MAYA).first

    assert_equal ["swift", "InboxSummary"], [summary.kind, summary.text]
    assert_equal [%w[prop inbox Support], %w[number unread 2], %w[number showing 2], %w[flag filtered false], %w[flag more false]],
      summary.children.map { |node| [node.kind, node.id, node.text] }

    ThreadScreen.new(MAYA.merge("id" => @newer.id)).perform("open", {})

    assert_equal %w[Support 1 1 true false], list(UNREAD).first.children.map(&:text)
    assert_equal %w[Billing 1 1 false false], list("member" => "maya", "inbox" => "billing").first.children.map(&:text)
  end

  test "an inbox longer than a page says the server has more and offers to load it" do
    travel_to(1.hour.ago) { MailEntry::PAGE_SIZE.times { |n| write("support", "rae", "Old #{n}") } }

    summary = list(MAYA).first
    last = list(MAYA).last

    assert_equal MailEntry::PAGE_SIZE, rows_for(MAYA).size
    assert_equal "true", summary.children.find { |node| node.id == "more" }.text
    assert_equal ["button", "Load older mail", "older"], [last.kind, last.text, last.action]
    assert_equal "row", list("member" => "maya", "inbox" => "billing").last.kind
  end

  test "the list can be pulled to refresh" do
    assert_equal "true", MailboxScreen.new(MAYA).render.children.first.children.first.props["refresh"]
  end

  private

  def toolbar(params)
    MailboxScreen.new(params).render.children.first.children.find { |node| node.kind == "toolbar" }.children
  end

  def write(inbox, author, subject)
    Mailbox.find(inbox).append!(id: SecureRandom.uuid, author: author,
      attributes: { kind: "message", address: "#{author}@example.test", subject: subject, body: "Hello" })
  end

  def rows_for(params)
    list(params).select { |node| node.kind == "row" }
  end

  def list(params) = MailboxScreen.new(params).render.children.first.children.first.children

  def kinds(row) = row.children.first.children.map(&:kind)

  def texts(row) = row.children.select { |node| node.kind == "text" }.map(&:text)
end
