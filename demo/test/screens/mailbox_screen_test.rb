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
    assert_equal "maya/support/#{@newer.id}", rows.first.arg
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

  test "opening unread mail marks it read, once" do
    screen = MailboxScreen.new("maya/support")

    assert_difference -> { MailEntry.where(kind: "read", parent_id: @newer.id, author: "maya").count }, 1 do
      screen.perform("read", "maya/support/#{@newer.id}")
      screen.perform("read", "maya/support/#{@newer.id}")
    end
    assert_not_includes kinds(rows_for("maya/support").first), "image"
    assert_includes kinds(rows_for("theo/support").first), "image"
  end

  test "archiving takes the message off the list for everyone in the inbox" do
    MailboxScreen.new("maya/support").perform("archive", "maya/support/#{@newer.id}")

    assert_equal [@older.id], rows_for("maya/support").map(&:id)
    assert_equal [@older.id], rows_for("theo/support").map(&:id)
  end

  test "an action on another inbox's mail, or by someone outside the inbox, does nothing" do
    assert_no_difference -> { MailEntry.count } do
      MailboxScreen.new("maya/support").perform("archive", "maya/billing/#{@newer.id}")
      MailboxScreen.new("jo/support").perform("archive", "jo/support/#{@newer.id}")
      MailboxScreen.new("maya/support").perform("archive", "maya/support/missing")
    end
    assert_empty rows_for("jo/support")
  end

  test "the leading menu lists the member's inboxes, each opening in place of this one, with this one selected" do
    menu = toolbar("maya/support").first

    assert_equal ["leading", "person.crop.circle"], [menu.props["position"], menu.props["image"]]
    assert_equal %w[Support Billing], menu.children.map(&:text)
    assert_equal %w[mailbox mailbox], menu.children.map { |item| item.props["link"] }
    assert_equal %w[maya/support maya/billing], menu.children.map(&:arg)
    assert_equal ["true", nil], menu.children.map { |item| item.props["selected"] }
    assert_equal [nil, "true"], toolbar("maya/billing").first.children.map { |item| item.props["selected"] }
    assert_equal %w[Support], toolbar("theo/support").first.children.map(&:text)
  end

  test "the trailing menu chooses all mail or unread mail, and the choice travels in the screen's argument" do
    all, unread, mark = toolbar("maya/support").last.children

    assert_equal ["trailing", "slider.horizontal.3"], toolbar("maya/support").last.props.values_at("position", "image")
    assert_equal [%w[All maya/support true], ["Unread", "maya/support/unread", nil]], [all, unread].map { |item| [item.text, item.arg, item.props["selected"]] }
    assert_equal ["Mark all read", "read_all", "maya/support"], [mark.text, mark.action, mark.arg]
    assert_equal [nil, "true"], toolbar("maya/support/unread").last.children.first(2).map { |item| item.props["selected"] }
  end

  test "unread only lists what this member has not read" do
    MailboxScreen.new("maya/support").perform("read", "maya/support/#{@newer.id}")

    assert_equal [@older.id], rows_for("maya/support/unread").map(&:id)
    assert_equal [@newer.id, @older.id], rows_for("maya/support").map(&:id)
    assert_equal "maya/support/#{@older.id}", rows_for("maya/support/unread").first.arg
  end

  test "mark all read reads the listed mail for this member alone, once" do
    assert_difference -> { MailEntry.where(kind: "read", author: "maya").count }, 2 do
      MailboxScreen.new("maya/support").perform("read_all", "maya/support")
      MailboxScreen.new("maya/support").perform("read_all", "maya/support")
    end
    assert_empty rows_for("maya/support/unread")
    assert_equal 2, rows_for("theo/support/unread").size
    assert_no_difference -> { MailEntry.count } do
      MailboxScreen.new("maya/support").perform("read_all", "maya/billing")
      MailboxScreen.new("jo/support").perform("read_all", "jo/support")
    end
  end

  test "a Swift view heads the list with what the inbox holds for this member" do
    summary = list("maya/support").first

    assert_equal ["swift", "InboxSummary"], [summary.kind, summary.text]
    assert_equal({ "inbox" => "Support", "unread" => "2", "showing" => "2", "filter" => "all" }, summary.children.to_h { |prop| [prop.id, prop.text] })

    MailboxScreen.new("maya/support").perform("read", "maya/support/#{@newer.id}")

    assert_equal %w[Support 1 1 unread], list("maya/support/unread").first.children.map(&:text)
    assert_equal %w[Billing 1 1 all], list("maya/billing").first.children.map(&:text)
  end

  test "the list can be pulled to refresh" do
    assert_equal "true", MailboxScreen.new("maya/support").render.children.first.children.first.props["refresh"]
  end

  private

  def toolbar(arg)
    MailboxScreen.new(arg).render.children.first.children.find { |node| node.kind == "toolbar" }.children
  end

  def write(inbox, author, subject)
    Mailbox.find(inbox).append!(id: SecureRandom.uuid, author: author,
      attributes: { kind: "message", address: "#{author}@example.test", subject: subject, body: "Hello" })
  end

  def rows_for(arg)
    list(arg).select { |node| node.kind == "row" }
  end

  def list(arg) = MailboxScreen.new(arg).render.children.first.children.first.children

  def kinds(row) = row.children.first.children.map(&:kind)

  def texts(row) = row.children.select { |node| node.kind == "text" }.map(&:text)
end
