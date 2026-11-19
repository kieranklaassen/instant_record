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

  private

  def write(inbox, author, subject)
    Mailbox.find(inbox).append!(id: SecureRandom.uuid, author: author,
      attributes: { kind: "message", address: "#{author}@example.test", subject: subject, body: "Hello" })
  end

  def rows_for(arg)
    MailboxScreen.new(arg).render.children.first.children.first.children
  end

  def kinds(row) = row.children.first.children.map(&:kind)

  def texts(row) = row.children.select { |node| node.kind == "text" }.map(&:text)
end
