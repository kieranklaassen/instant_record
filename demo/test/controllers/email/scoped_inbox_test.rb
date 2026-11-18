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

  test "Rails compose, reply and archive go through the same feed" do
    post "/email", params: { member: "theo", inbox: "support", kind: "message", address: "rae@example.test", subject: "Hello", body: "Hi" }
    assert_response :redirect
    follow_redirect!
    assert_select ".mail-thread h2", "Hello"
    thread = MailEntry.sole.id
    post "/email", params: { member: "maya", inbox: "support", kind: "reply", parent_id: thread, body: "Got it" }
    follow_redirect!
    assert_select ".mail-thread p", "Got it"
    post "/email", params: { member: "theo", inbox: "support", kind: "archive", parent_id: thread }
    follow_redirect!
    assert_select ".mail-list a", count: 0
    get "/email/sync/theo/support/events?after=1"
    assert_match(/id: 2.*id: 3/m, response.body)
  end
end
