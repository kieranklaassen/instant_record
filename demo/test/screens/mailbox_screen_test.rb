require "test_helper"

class MailboxScreenTest < ActiveSupport::TestCase
  setup do
    MailEntry.delete_all
    Mailbox.delete_all
    @support = Mailbox.create!(id: "support")
    Mailbox.create!(id: "billing")
    travel_to(2.minutes.ago) { @older = write("support", "rae", "Night shift") }
    @newer = write("support", "sam", "October invoice")
    write("billing", "jo", "Receipt")
  end

  test "lists one inbox's open mail newest first" do
    rows = rows_for("maya/support")

    assert_equal [@newer.id, @older.id], rows.map(&:id)
    assert_equal %w[thread thread], rows.map { |row| row.props["link"] }
    assert_equal({ "member" => "maya", "inbox" => "support", "thread" => @newer.id }, rows.first.link_params)
    assert_equal ["", {}], [rows.first.action, rows.first.args]
    assert_includes texts(rows.first), "October invoice"
  end

  test "leaves out archived mail" do
    @support.append!(id: SecureRandom.uuid, author: "theo", attributes: { kind: "archive", parent_id: @newer.id })

    assert_equal [@older.id], rows_for("maya/support").map(&:id)
  end

  test "marks mail this member has not read, and not mail they wrote" do
    mine = write("support", "maya", "From me")

    unread = rows_for("maya/support").select { |row| kinds(row).include?("image") }.map(&:id)

    assert_equal [@newer.id, @older.id], unread
    assert_not_includes unread, mine.id
  end

  test "a row keeps the sender to one line with the date at the far edge, and the preview to two" do
    head, subject, preview = rows_for("maya/support").first.children

    assert_equal %w[image text spacer date], head.children.map(&:kind)
    assert_equal ["unread", "1"], [head.children.first.text, head.children[1].props["lines"]]
    assert_equal %w[1 2], [subject, preview].map { |text| text.props["lines"] }
  end

  test "a render asks the database the same number of questions however much mail is listed" do
    queries = lambda do
      asked = 0
      counter = ->(*, payload) { asked += 1 unless payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { MailboxScreen.new(at("maya/support")).render }
      asked
    end
    queries.call
    few = queries.call
    12.times { |n| write("support", "rae", "More #{n}") }

    assert_equal few, queries.call
  end

  test "an inbox with nothing in it says so, in the words of the view it is" do
    MailEntry.where(mailbox_id: "support").delete_all

    assert_equal ["No mail"], list("maya/support").select { |node| node.kind == "text" }.map(&:text)
    assert_equal ["You're all caught up"], list("maya/support/unread").select { |node| node.kind == "text" }.map(&:text)
    assert_empty list("maya/support").select { |node| node.kind == "more" }
  end

  test "the server shows the first page whole and asks for no more" do
    (MailEntry::PAGE_SIZE + 5).times { |n| write("support", "rae", "Bulk #{n}") }

    assert_equal MailEntry::PAGE_SIZE, rows_for("maya/support").size
    assert_empty list("maya/support").select { |node| node.kind == "more" }
    assert_equal "false", summary("maya/support")["more"]
  end

  test "archiving takes the message off the list for everyone in the inbox" do
    MailboxScreen.new(at("maya/support")).perform("archive", { "id" => @newer.id }, {})

    assert_equal [@older.id], rows_for("maya/support").map(&:id)
    assert_equal [@older.id], rows_for("theo/support").map(&:id)
  end

  test "an action on another inbox's mail, or by someone outside the inbox, does nothing" do
    assert_no_difference -> { MailEntry.count } do
      MailboxScreen.new(at("maya/billing")).perform("archive", { "id" => @newer.id }, {})
      MailboxScreen.new(at("jo/support")).perform("archive", { "id" => @newer.id }, {})
      MailboxScreen.new(at("maya/support")).perform("archive", { "id" => "missing" }, {})
      MailboxScreen.new(at("maya/support")).perform("archive", {}, {})
    end
    assert_empty rows_for("jo/support")
  end

  test "the leading menu lists the member's inboxes, each opening in place of this one, with this one selected" do
    menu = toolbar("maya/support").first

    assert_equal ["leading", "person"], [menu.props["position"], menu.props["image"]]
    assert_equal %w[Support Billing], menu.children.map(&:text)
    assert_equal %w[mailbox mailbox], menu.children.map { |item| item.props["replace"] }
    assert_equal [nil, nil], menu.children.map { |item| item.props["link"] }
    assert_equal [at("maya/support"), at("maya/billing")], menu.children.map(&:link_params)
    assert_equal ["true", nil], menu.children.map { |item| item.props["selected"] }
    assert_equal [nil, "true"], toolbar("maya/billing").first.children.map { |item| item.props["selected"] }
    assert_equal %w[Support], toolbar("theo/support").first.children.map(&:text)
  end

  test "the trailing menu chooses all mail or unread mail, and the choice travels in the screen's params" do
    all, unread, mark = toolbar("maya/support").last.children

    assert_equal ["trailing", "filter"], toolbar("maya/support").last.props.values_at("position", "image")
    assert_equal [["All", at("maya/support"), "true"], ["Unread", at("maya/support/unread"), nil]], [all, unread].map { |item| [item.text, item.link_params, item.props["selected"]] }
    assert_equal ["Mark 2 as read", "read_all", {}], [mark.text, mark.action, mark.args]
    assert_equal [nil, "true"], toolbar("maya/support/unread").last.children.first(2).map { |item| item.props["selected"] }
  end

  test "the trailing menu ends with a way to send feedback, in a sheet over the mailbox" do
    feedback = toolbar("maya/support/unread").last.children.last

    assert_equal ["Send feedback", "feedback", nil, nil], [feedback.text, feedback.props["sheet"], feedback.props["link"], feedback.props["replace"]]
    assert_equal at("maya/support"), feedback.link_params
  end

  test "unread only lists what this member has not read" do
    read(@newer)

    assert_equal [@older.id], rows_for("maya/support/unread").map(&:id)
    assert_equal [@newer.id, @older.id], rows_for("maya/support").map(&:id)
    assert_equal @older.id, rows_for("maya/support/unread").first.link_params["thread"]
    assert_nil rows_for("maya/support/unread").first.link_params["filter"]
  end

  test "mark all read reads the listed mail for this member alone, once" do
    assert_difference -> { MailEntry.where(kind: "read", author: "maya").count }, 2 do
      MailboxScreen.new(at("maya/support")).perform("read_all", {}, {})
      MailboxScreen.new(at("maya/support")).perform("read_all", {}, {})
    end
    assert_empty rows_for("maya/support/unread")
    assert_equal ["All", "Unread", "Send feedback"], toolbar("maya/support").last.children.map(&:text)
    assert_equal 2, rows_for("theo/support/unread").size
    assert_no_difference -> { MailEntry.count } do
      MailboxScreen.new(at("jo/support")).perform("read_all", {}, {})
      MailboxScreen.new(at("jo/nowhere")).perform("read_all", {}, {})
    end
  end

  test "a Swift view heads the list with what the inbox holds for this member" do
    summary = list("maya/support").first

    assert_equal ["swift", "InboxSummary"], [summary.kind, summary.text]
    assert_equal({ "inbox" => "Support", "unread" => "2", "showing" => "2", "filtered" => "false", "more" => "false" }, summary.children.to_h { |prop| [prop.props["name"], prop.text] })
    assert_equal %w[string int int bool bool], summary.children.map { |prop| prop.props["type"] }

    read(@newer)

    assert_equal %w[Support 1 1 true false], list("maya/support/unread").first.children.map(&:text)
    assert_equal %w[Billing 1 1 false false], list("maya/billing").first.children.map(&:text)
  end

  test "the list can be pulled to refresh" do
    assert_equal "true", MailboxScreen.new(at("maya/support")).render.children.first.children.first.props["refresh"]
  end

  test "a message whose id is a word the screen uses is still that message" do
    odd = @support.append!(id: "unread", author: "rae", attributes: { kind: "message", address: "rae@example.test", subject: "Odd id", body: "Hello" })

    assert_equal "unread", rows_for("maya/support").first.link_params["thread"]
    MailboxScreen.new(at("maya/support")).perform("archive", { "id" => odd.id }, {})
    assert_not_includes rows_for("maya/support").map(&:id), "unread"
  end

  private

  # "maya/support/unread" as the params a host would send.
  def at(path)
    member, inbox, filter = path.split("/")
    { "member" => member, "inbox" => inbox, "filter" => filter }.compact
  end

  def toolbar(arg)
    MailboxScreen.new(at(arg)).render.children.first.children.find { |node| node.kind == "toolbar" }.children
  end

  def read(entry)
    @support.append!(id: SecureRandom.uuid, author: "maya", attributes: { kind: "read", parent_id: entry.id })
  end

  def summary(arg) = list(arg).first.children.to_h { |prop| [prop.props["name"], prop.text] }

  def write(inbox, author, subject)
    Mailbox.find(inbox).append!(id: SecureRandom.uuid, author: author,
      attributes: { kind: "message", address: "#{author}@example.test", subject: subject, body: "Hello" })
  end

  def rows_for(arg)
    list(arg).select { |node| node.kind == "row" }
  end

  def list(arg) = MailboxScreen.new(at(arg)).render.children.first.children.first.children

  def kinds(row) = row.children.first.children.map(&:kind)

  def texts(row) = row.children.select { |node| node.kind == "text" }.map(&:text)
end
