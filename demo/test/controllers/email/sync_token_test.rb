require "test_helper"

class Email::SyncTokenTest < ActionDispatch::IntegrationTest
  BOOTSTRAP = "/instant_record/bootstrap"

  setup do
    InstantRecord::Change.delete_all
    InstantRecord::AppliedMutation.delete_all
    MailEntry.delete_all
    Mailbox.delete_all
    Mailbox.create!(id: "support")
  end

  teardown { ENV.delete("INBOX_REQUIRE_TOKEN") }

  test "a request that says nothing about who is asking is served as before" do
    get BOOTSTRAP, headers: inbox_headers("maya", "support")

    assert_response :success
  end

  test "a token for the member in the header is accepted, on a read and on a write" do
    get BOOTSTRAP, headers: inbox_headers("maya", "support").merge(bearer(MailDirectory.token("maya")))
    assert_response :success

    write = { id: "m1", operation: "create", record_type: "MailEntry", record_id: SecureRandom.uuid,
      changes: { mailbox_id: "support", author: "maya", kind: "message", address: "maya@example.test", subject: "Hi", body: "Hello" } }
    post "/instant_record/mutations", params: { mutations: [write] }, as: :json,
      headers: inbox_headers("maya", "support").merge(bearer(MailDirectory.token("maya")))
    assert_response :success
    assert_equal "applied", response.parsed_body.dig("results", 0, "status")
  end

  test "a token for someone else, a changed token and a header that is not a bearer token are refused" do
    [MailDirectory.token("theo"), MailDirectory.token("maya") + "x", "not-a-token"].each do |token|
      get BOOTSTRAP, headers: inbox_headers("maya", "support").merge(bearer(token))
      assert_response :unauthorized, token
    end

    get BOOTSTRAP, headers: inbox_headers("maya", "support").merge("Authorization" => "Basic bWF5YTpzZWNyZXQ=")
    assert_response :unauthorized
  end

  test "a token made for another purpose is not a sync token" do
    get BOOTSTRAP, headers: inbox_headers("maya", "support").merge(
      bearer(Rails.application.message_verifier(:inbox_sync).generate("maya", purpose: :something_else))
    )

    assert_response :unauthorized
  end

  test "a server that requires a token refuses a request without one and serves one with it" do
    ENV["INBOX_REQUIRE_TOKEN"] = "1"

    get BOOTSTRAP, headers: inbox_headers("maya", "support")
    assert_response :unauthorized

    get BOOTSTRAP, headers: inbox_headers("maya", "support").merge(bearer(MailDirectory.token("maya")))
    assert_response :success

    get BOOTSTRAP, headers: inbox_headers("theo", "support").merge(bearer(MailDirectory.token("maya")))
    assert_response :unauthorized
  end

  test "the browser's preflight is answered without a token" do
    ENV["INBOX_REQUIRE_TOKEN"] = "1"

    options "/instant_record/mutations"
    assert_response :no_content

    options "/instant_record/bootstrap"
    assert_response :no_content
  end

  private

  def inbox_headers(member, inbox)
    { "X-Instant-Record-Partition" => "mailbox_id:#{inbox}", "X-Instant-Record-Member" => member }
  end

  def bearer(token) = { "Authorization" => "Bearer #{token}" }
end
