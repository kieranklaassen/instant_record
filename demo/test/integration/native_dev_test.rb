require "test_helper"

# The development road for a native app's screens: the phone asks this server
# for a screen and gets what its compiled library would have drawn.
class NativeDevTest < ActionDispatch::IntegrationTest
  MAYA = { "member" => "maya", "inbox" => "support" }.freeze

  setup do
    MailEntry.delete_all
    Mailbox.delete_all
    @support = Mailbox.create!(id: "support")
    @message = @support.append!(id: SecureRandom.uuid, author: "rae",
      attributes: { kind: "message", address: "rae@example.test", subject: "Night shift", body: "Hello" })
    @was = Rails.application.config.instant_record.native_dev
    Rails.application.config.instant_record.native_dev = true
  end

  teardown { Rails.application.config.instant_record.native_dev = @was }

  test "a screen is answered as the screen class draws it" do
    ask "render", { screen: "mailbox", params: MAYA }

    assert_response :success
    assert_equal JSON.parse(MailboxScreen.new(MAYA).json), response.parsed_body
  end

  test "an action is performed, with the values it carries, and the next render shows it" do
    ask "action", { screen: "thread", params: MAYA.merge("thread" => @message.id), action: "reply", values: { "body" => "On it.\n\"Now\"" } }
    assert_response :no_content
    assert_equal "On it.\n\"Now\"", MailEntry.find_by(kind: "reply", parent_id: @message.id, author: "maya").body

    ask "action", { screen: "mailbox", params: MAYA, action: "archive", args: { "id" => @message.id } }
    ask "render", { screen: "mailbox", params: MAYA }

    assert_empty response.parsed_body.dig("children", 0, "children", 0, "children").select { |node| node["kind"] == "row" }
  end

  test "a screen nobody wrote is not found, and says which" do
    ask "render", { screen: "nowhere", params: MAYA }

    assert_response :not_found
    assert_equal "No screen named nowhere", response.body
  end

  test "it answers nothing unless the app turned it on" do
    Rails.application.config.instant_record.native_dev = false

    ask "render", { screen: "mailbox", params: MAYA }
    assert_response :not_found
    ask "action", { screen: "mailbox", params: MAYA, action: "archive", args: { "id" => @message.id } }
    assert_response :not_found
    assert_not MailEntry.exists?(kind: "archive")
  end

  test "it answers nothing outside a local environment, even when turned on" do
    Rails.env = "production"
    ask "render", { screen: "mailbox", params: MAYA }

    assert_response :not_found
  ensure
    Rails.env = "test"
  end

  test "it answers nothing to a request from another machine" do
    ask "render", { screen: "mailbox", params: MAYA }, { "REMOTE_ADDR" => "203.0.113.7" }
    assert_response :not_found

    ask "action", { screen: "mailbox", params: MAYA, action: "archive", args: { "id" => @message.id } }, { "REMOTE_ADDR" => "203.0.113.7" }
    assert_response :not_found
    assert_not MailEntry.exists?(kind: "archive")
  end

  test "a request that is not JSON is refused, as a form's post would be" do
    post "/instant_record/native/action", params: { screen: "mailbox", action: "archive" }

    assert_response :unsupported_media_type
  end

  test "a name that could not be a screen's, or that names another class, is not found" do
    ["Mail Entry", "mail_entry", "../x", ""].each do |name|
      ask "render", { screen: name, params: MAYA }
      assert_response :not_found, name
    end
  end

  test "input that is not an object is no screen" do
    post "/instant_record/native/render", params: "[1]", headers: { "CONTENT_TYPE" => "application/json" }

    assert_response :not_found
  end

  test "a web page cannot drive it: no CORS headers, and no preflight" do
    ask "render", { screen: "mailbox", params: MAYA }
    assert_nil response.headers["access-control-allow-origin"]

    options "/instant_record/native/render"
    assert_response :not_found
  end

  private

  def ask(entry, body, headers = {})
    post "/instant_record/native/#{entry}", params: JSON.generate(body), headers: { "CONTENT_TYPE" => "application/json" }.merge(headers)
  end
end
