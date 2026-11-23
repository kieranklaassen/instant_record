require "test_helper"

class ScopedInboxTest < ActionDispatch::IntegrationTest
  setup do
    MailEntry.delete_all
    Mailbox.delete_all
    %w[support billing].each { |name| Mailbox.create!(id: name) }
  end

  def mutation(inbox, member, fields = {})
    { id: SecureRandom.uuid, record_type: "MailEntry", record_id: SecureRandom.uuid, operation: "create",
      changes: { kind: "message", address: "rae@example.test", subject: "Request", body: "Can you help?", mailbox_id: inbox, author: member }.merge(fields) }
  end

  def push(person, box, item)
    post "/email/sync/#{person}/#{box}/mutations", params: { mutations: [item] }, as: :json
    assert_response :success
    response.parsed_body.fetch("results").sole
  end

  test "two teammates see an inbox and a member of both receives only the selected feed" do
    support = mutation("support", "maya")
    billing = mutation("billing", "jo")
    result = push("maya", "support", support)
    assert_equal "applied", result["status"]
    assert_equal result, push("maya", "support", support)
    collision = support.deep_dup
    collision[:changes][:body] = "Different message"
    assert_equal "rejected", push("maya", "support", collision)["status"]
    assert_equal "applied", push("jo", "billing", billing)["status"]
    assert_equal 1, Mailbox.find("support").revision

    get "/email/sync/theo/support/bootstrap"
    assert_equal [support[:record_id]], response.parsed_body["records"].pluck("id")
    get "/email/sync/maya/billing/events?after=0"
    assert_includes response.body, billing[:record_id]
    assert_not_includes response.body, support[:record_id]
    get "/email/sync/maya/billing/events?after=1"
    assert_empty response.body

    get "/instant_record/bootstrap"
    assert_not_includes response.body, support[:record_id]
    get "/instant_record/events?window=0"
    assert_not_includes response.body, support[:record_id]
    post "/instant_record/mutations", params: { mutations: [support] }, as: :json
    assert_equal "rejected", response.parsed_body["results"].sole["status"]
  end

  test "all scoped endpoints require membership and cross-inbox references are rejected" do
    get "/email/sync/jo/support/bootstrap"
    assert_response :forbidden
    get "/email/sync/jo/support/records", params: { thread: "hidden" }
    assert_response :forbidden
    get "/email/sync/jo/support/events"
    assert_response :forbidden
    post "/email/sync/jo/support/mutations", params: { mutations: [mutation("support", "jo")] }, as: :json
    assert_response :forbidden
    get "/email?member=jo&inbox=support"
    assert_response :forbidden

    parent = mutation("billing", "maya")
    push("maya", "billing", parent)
    %w[reply archive].each do |kind|
      item = mutation("support", "theo", kind: kind, parent_id: parent[:record_id])
      assert_equal "rejected", push("theo", "support", item)["status"]
    end
    assert_equal "rejected", push("theo", "support", mutation("billing", "theo"))["status"]
    assert_equal "rejected", push("theo", "support", mutation("support", "maya"))["status"]
    assert_equal 0, Mailbox.find("support").revision
  end

  test "empty installs populate only the requested mailbox and validate recipients" do
    Mailbox.delete_all
    get "/email/sync/maya/billing/bootstrap"
    assert_equal ["billing"], Mailbox.pluck(:id)
    assert_equal ["sam@example.test"], response.parsed_body["records"].map { |row| row.dig("attributes", "address") }
    post "/email", params: { member: "jo", inbox: "billing", kind: "message", address: "missing-address", subject: "Hello", body: "Hi" }
    assert_response :unprocessable_entity
    assert_equal 1, MailEntry.count
  end

  test "mail pages break timestamp ties by id and omit archived conversations" do
    mailbox = Mailbox.find("support")
    ids = Array.new(53) { |i| "tied-%02d" % i }
    at = Time.utc(2024, 5, 1)
    ids.each do |id|
      mailbox.append!(id: id, author: "maya", attributes: { kind: "message", address: "rae@example.test", subject: id, body: id })
    end
    MailEntry.where(id: ids).update_all(created_at: at)
    mailbox.append!(id: "archive", author: "theo", attributes: { kind: "archive", parent_id: ids.last })
    get "/email/sync/maya/support/bootstrap"
    page = response.parsed_body.fetch("records").pluck("id")
    assert_equal ids.reverse.drop(1).first(50), page
    get "/email/sync/maya/support/records", params: { type: "MailEntry", before_id: page.last, before_created_at: at.iso8601 }
    assert_equal ids.first(2).reverse, response.parsed_body.fetch("records").pluck("id")
    assert_equal false, response.parsed_body.fetch("has_more")
  end

  test "generated mail arrives from an external sender only in the selected inbox" do
    post "/email/sync/jo/support/incoming"
    assert_response :forbidden
    assert_no_difference("Mailbox.find('billing').revision") do
      assert_difference("MailEntry.count", 1) { post "/email/sync/theo/support/incoming" }
    end
    assert_response :created
    id = response.parsed_body.fetch("id")
    entry = MailEntry.find(id)
    assert_equal ["message", "support"], [entry.kind, entry.mailbox_id]
    assert_not_includes %w[maya theo jo], entry.author
    get "/email/sync/maya/support/events?after=0"
    assert_includes response.body, id
    get "/email/sync/maya/billing/bootstrap"
    assert_empty response.parsed_body.fetch("records")
  end

  # What the page is given: its Inertia props on a first visit, and one of
  # them again on a partial reload, which is how a live prop is refreshed.
  def initial_page
    assert_response :success
    JSON.parse(css_select("#app[data-page]").first["data-page"])
  end

  def page_props
    initial_page.fetch("props")
  end

  def live(member, prop, extra = {})
    get "/email", params: { member: member, inbox: "support" }.merge(extra),
      headers: { "X-Inertia" => "true", "X-Inertia-Partial-Component" => "Email/Inbox", "X-Inertia-Partial-Data" => prop }
    assert_response :success
    assert_equal "true", response.headers["X-Inertia"]
    assert_equal "X-Inertia", response.headers["Vary"]
    assert_equal [prop, "errors"].sort, response.parsed_body["props"].keys.sort
    response.parsed_body.dig("props", prop)
  end

  def unread_ids(mail) = mail["rows"].select { |row| row[6] == "1" }.map(&:first)

  test "the first paint is an Inertia page whose props hold the first screen of mail" do
    entry = Mailbox.find("support").generate_incoming!
    get "/email", params: { member: "maya", inbox: "support" }
    assert_select "script[type='module'][src*='inbox']"
    page = initial_page
    assert_equal "Email/Inbox", page["component"]
    props = page["props"]
    assert_equal %w[support billing], props["inboxes"]
    assert_equal [entry.id, entry.author, entry.address, entry.subject, entry.body, entry.created_at.utc.iso8601(6), "1", "1"], props.dig("mail", "rows", 0)
    assert_equal entry.id, props.dig("thread", "id")
    assert_equal props["mail"], live("maya", "mail")
    # Both props are live: Inertia reloads each when InstantRecord says the
    # local database changed.
    assert_equal %w[mail thread], page["liveProps"].keys
    assert_equal [{ "channel" => { "name" => "instant_record", "type" => "local" }, "events" => ["MailEntry"] }], page.dig("liveProps", "mail", "listeners")
    assert_equal InstantRecord::Inertia.live_props(mail: MailEntry, thread: MailEntry).as_json, page["liveProps"]
    assert_equal page["liveProps"], response.parsed_body["liveProps"]
  end

  test "a write returns the reader to the page they were on" do
    entry = Mailbox.find("support").generate_incoming!
    here = "/email?member=maya&inbox=support&thread=#{entry.id}&limit=100"
    post "/email", params: { member: "maya", inbox: "support", kind: "read", parent_id: entry.id },
      headers: { "X-Inertia" => "true", "Referer" => "http://www.example.com#{here}" }
    assert_redirected_to here
    assert_response :see_other
  end

  test "the list is one query that widens, newest first, and says when more is held" do
    box = Mailbox.find("support")
    60.times { |i| box.append!(id: "m#{i}", author: "Rae", attributes: { kind: "message", address: "rae@example.test", subject: "S#{i}", body: "B" }) }
    mail = live("maya", "mail")
    assert_equal 50, mail["rows"].size
    assert_equal true, mail["more"]
    assert_equal 50, mail["limit"]
    assert_equal "m59", mail["rows"].first.first
    mail = live("maya", "mail", limit: 100)
    assert_equal 60, mail["rows"].size
    assert_equal false, mail["more"]
    assert_equal 60, mail["unread_count"]
    assert_equal MailEntry::LIVE_LIMIT, live("maya", "mail", limit: 1_000_000)["limit"]
  end

  test "the list widens to hold the conversation the address names" do
    box = Mailbox.find("support")
    120.times { |i| box.append!(id: "m#{i}", author: "Rae", attributes: { kind: "message", address: "rae@example.test", subject: "S#{i}", body: "B" }) }
    mail = live("maya", "mail", thread: "m45")
    assert_equal 100, mail["limit"]
    assert_includes mail["rows"].map(&:first), "m45"
    assert_equal 50, live("maya", "mail", thread: "m119")["limit"]
    assert_equal 50, live("maya", "mail", thread: "nobody")["limit"]
  end

  test "Rails compose, reply and archive go through the same feed" do
    post "/email", params: { member: "theo", inbox: "support", kind: "message", address: "rae@example.test", subject: "Hello", body: "Hi" }
    thread = MailEntry.sole.id
    assert_redirected_to "/email?member=theo&inbox=support&thread=#{thread}"
    follow_redirect!
    assert_equal "Hello", page_props.dig("thread", "message", 3)
    post "/email", params: { member: "maya", inbox: "support", kind: "reply", parent_id: thread, body: "Got it" }
    assert_response :redirect
    reply = live("theo", "thread", thread: thread)["replies"].sole
    assert_equal ["maya", "Got it"], reply[1, 2]
    post "/email", params: { member: "theo", inbox: "support", kind: "archive", parent_id: thread }
    assert_empty live("theo", "mail")["rows"]
    assert_equal true, live("maya", "thread", thread: thread)["archived"]
    assert_equal "", live("maya", "thread", thread: "missing")["id"]
    get "/email/sync/theo/support/events?after=1"
    assert_match(/id: 2.*id: 3/m, response.body)
  end

  test "each teammate reads mail on their own and can mark it unread again" do
    first = Mailbox.find("support").generate_incoming!
    second = Mailbox.find("support").generate_incoming!
    mail = live("maya", "mail")
    assert_equal [second.id, first.id], unread_ids(mail)
    assert_equal 2, mail["unread_count"]

    # Looking does not read: a visit and a live query write nothing.
    assert_no_difference("MailEntry.count") do
      get "/email", params: { member: "maya", inbox: "support", thread: first.id }
      assert_equal "1", page_props.dig("thread", "message", 6)
      live("maya", "thread", thread: first.id)
    end

    post "/email", params: { member: "maya", inbox: "support", kind: "read", parent_id: first.id }
    assert_redirected_to "/email?member=maya&inbox=support&thread=#{first.id}"
    assert_equal [second.id], unread_ids(live("maya", "mail"))
    assert_equal "", live("maya", "thread", thread: first.id)["message"][6]
    assert_equal 2, live("theo", "mail")["unread_count"]

    post "/email", params: { member: "maya", inbox: "support", kind: "unread", parent_id: first.id }
    assert_redirected_to "/email?member=maya&inbox=support"
    assert_equal 2, live("maya", "mail")["unread_count"]

    post "/email", params: { member: "theo", inbox: "support", kind: "message", address: "rae@example.test", subject: "Sent", body: "Hi" }
    sent = live("theo", "mail")["rows"].first
    assert_equal ["Sent", "", ""], [sent[3], sent[6], sent[7]]
    get "/email/sync/theo/support/bootstrap"
    assert_includes response.parsed_body["records"].map { |row| row.dig("attributes", "kind") }, "unread"
  end
end
