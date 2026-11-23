require "test_helper"

# Search and the background fill, as InstantRecord::Engine and the Rails page answer them.
class MailSearchAndFillTest < ActionDispatch::IntegrationTest
  setup do
    InstantRecord::Change.delete_all
    MailEntry.delete_all
    Mailbox.delete_all
    @mailbox = Mailbox.create!(id: "support")
    Mailbox.create!(id: "billing")
  end

  def inbox_headers(member = "maya", inbox = "support")
    { "X-Instant-Record-Partition" => "mailbox_id:#{inbox}", "X-Instant-Record-Member" => member }
  end

  def write(subject, body: "Can you help?", author: "Rae", mailbox: @mailbox)
    mailbox.append!(id: SecureRandom.uuid, author: author, attributes: { kind: "message", address: "rae@example.test", subject: subject, body: body })
  end

  def records(params)
    get "/instant_record/records", params: params, headers: inbox_headers
    assert_response :success
    response.parsed_body
  end

  def mail(params = {})
    get "/email", params: { member: "maya", inbox: "support" }.merge(params),
      headers: { "X-Inertia" => "true", "X-Inertia-Partial-Component" => "Email/Inbox", "X-Inertia-Partial-Data" => "mail" }
    assert_response :success
    response.parsed_body.dig("props", "mail")
  end

  test "the fill walks the whole inbox down from the newest page, with what rides on each conversation" do
    written = 7.times.map { |number| write("Request #{number}") }
    reply = @mailbox.append!(id: SecureRandom.uuid, author: "maya", attributes: { kind: "reply", parent_id: written.first.id, body: "On it" })
    archived = write("Closed")
    @mailbox.append!(id: SecureRandom.uuid, author: "maya", attributes: { kind: "archive", parent_id: archived.id, body: "" })

    # As compiled/web/src/history-fill.js starts: older than any row.
    before = { created_at: "9999-12-31T00:00:00.000000Z", id: "~" }
    seen = []
    with_page_size(3) do
      loop do
        page = records(type: "MailEntry", before_created_at: before[:created_at], before_id: before[:id], limit: 3)
        seen.concat(page["records"])
        if page["next_before"]
          before = { created_at: page["next_before"]["created_at"], id: page["next_before"]["id"] }
        end
        break unless page["has_more"]
      end
    end

    assert_equal (written.map(&:id) + [reply.id]).sort, seen.pluck("id").sort
  end

  test "a page is as big as it is asked for, within the fill's limit" do
    assert_equal 0, records(type: "MailEntry", before_created_at: "9999-12-31T00:00:00.000000Z", before_id: "~", limit: 100_000)["records"].size
    (MailEntry::PAGE_SIZE + 5).times { |number| write("Request #{number}") }
    start = { type: "MailEntry", before_created_at: "9999-12-31T00:00:00.000000Z", before_id: "~" }
    assert_equal MailEntry::PAGE_SIZE, records(start.merge(limit: 1))["records"].size
    assert_equal MailEntry::PAGE_SIZE + 5, records(start.merge(limit: MailEntry::FILL_PAGE_SIZE))["records"].size
  end

  test "a search finds open conversations by subject, body, sender and address, in any case" do
    invoice = write("October INVOICE")
    body = write("A question", body: "Where is my invoice?")
    sender = write("Hello", author: "Invoice Bot")
    write("Unrelated")
    closed = write("Invoice from last year")
    @mailbox.append!(id: SecureRandom.uuid, author: "maya", attributes: { kind: "archive", parent_id: closed.id, body: "" })
    write("Invoice elsewhere", mailbox: Mailbox.find("billing"))
    reply = @mailbox.append!(id: SecureRandom.uuid, author: "maya", attributes: { kind: "reply", parent_id: invoice.id, body: "Sent" })

    page = records(search: "invoice")
    assert_equal [invoice.id, body.id, sender.id, reply.id].sort, page["records"].pluck("id").sort
    assert_equal false, page["has_more"]
    assert_equal 4, records(search: "EXAMPLE.test")["records"].count { |record| record.dig("attributes", "kind") == "message" }
    assert_empty records(search: "nothing like it")["records"]

    # The Rails page answers the same search with no local database at all.
    assert_equal [sender.id, body.id, invoice.id], mail(q: " Invoice ")["rows"].map(&:first)
    assert_equal "Invoice", mail(q: " Invoice ")["q"]
    assert_equal 4, mail["rows"].size
  end

  test "a search pages below a row like the list does" do
    old, _middle, _new = 3.times.map { |number| write("Invoice #{number}") }
    with_page_size(2) do
      first = records(search: "invoice")
      assert_equal true, first["has_more"]
      last = first["next_before"]
      rest = records(search: "invoice", before_created_at: last["created_at"], before_id: last["id"])
      assert_equal [old.id], rest["records"].pluck("id")
      assert_equal false, rest["has_more"]
    end
  end

  test "a search is one inbox's and its member's" do
    get "/instant_record/records", params: { search: "invoice" }, headers: inbox_headers("jo", "support")
    assert_response :forbidden
    get "/instant_record/records", headers: inbox_headers("maya", "support")
    assert_response :bad_request
  end

  private

  def with_page_size(size)
    shape = MailEntry.instant_record_sync_shape
    old_limit, old_min, old_max = shape.limit, shape.min_limit, shape.max_limit
    shape.instance_variable_set(:@limit, size)
    shape.instance_variable_set(:@min_limit, size)
    shape.instance_variable_set(:@max_limit, size)
    yield
  ensure
    shape.instance_variable_set(:@limit, old_limit)
    shape.instance_variable_set(:@min_limit, old_min)
    shape.instance_variable_set(:@max_limit, old_max)
  end
end
