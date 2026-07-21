require "test_helper"

module InstantRecord
  class EventsControllerTest < ActionDispatch::IntegrationTest
    def create_change!(title)
      issue = Issue.new(title: title, state: "open")
      issue.id = SecureRandom.uuid
      issue.server_version = 1
      issue.save!
      InstantRecord::Change.create!(
        record_type: "Issue", record_id: issue.id, operation: "create",
        version: 1, attributes_payload: issue.attributes.except("sync_state")
      )
    end

    test "streams changes after the cursor in order with change id as event id" do
      first = create_change!("one")
      second = create_change!("two")

      get "/instant_record/events", params: { after: first.id }

      assert_response :success
      assert_equal "text/event-stream", response.headers["Content-Type"]
      assert_includes response.body, "id: #{second.id}\n"
      assert_includes response.body, "event: change\n"
      refute_includes response.body, "id: #{first.id}\n"

      data = response.body[/data: (.+)/, 1]
      event = JSON.parse(data)
      assert_equal "Issue", event["type"]
      assert_equal "two", event["attributes"]["title"]
    end

    test "reconnect via Last-Event-ID header resumes without duplicates" do
      first = create_change!("one")
      second = create_change!("two")

      get "/instant_record/events", headers: { "Last-Event-ID" => first.id.to_s }

      assert_includes response.body, "id: #{second.id}\n"
      refute_includes response.body, "id: #{first.id}\n"
    end

    test "no new changes yields an empty stream" do
      change = create_change!("only")

      get "/instant_record/events", params: { after: change.id }

      assert_response :success
      assert_equal "", response.body
    end
  end
end
