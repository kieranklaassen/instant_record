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

    test "streams changes after the cursor, parseable by the gem's own SSE parser" do
      first = create_change!("one")
      second = create_change!("two")

      get "/instant_record/events", params: { after: first.id }

      assert_response :success
      assert_equal "text/event-stream", response.headers["Content-Type"]

      # Round-trip through the client's parser: catches producer/parser drift.
      events = []
      InstantRecord::Client::Transport::SseParser.new { |e| events << e }.feed(response.body)

      event = events.sole
      assert_equal second.id, event["cursor"]
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

    test "polling sees changes committed after the first poll despite the query cache" do
      # The request executor enables the AR query cache; an in-request polling
      # loop must bypass it or every poll returns the first result forever.
      ActiveRecord::Base.cache do
        before = InstantRecord::Change.poll(0).size
        create_change!("late arrival")
        after = InstantRecord::Change.poll(0).size

        assert_equal before + 1, after, "later polls must see newly committed changes"
      end
    end

    test "polling releases its database connection (idle streams pin nothing)" do
      # A fresh thread has no leased connection; after a poll the lease must
      # be gone, or every idle SSE stream would pin a pool connection.
      Thread.new do
        InstantRecord::Change.poll(0)
        refute InstantRecord::Change.connection_pool.active_connection?,
          "Change.poll must release its connection between polls"
      end.join
    end
  end
end
