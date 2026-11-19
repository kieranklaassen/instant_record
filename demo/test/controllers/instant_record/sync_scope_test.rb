require "test_helper"

module InstantRecord
  # sync_scope over HTTP, with the Assistant's chats: what one browser's sync
  # requests are sent and what they may write. A visitor is the request's scope.
  class SyncScopeTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    setup do
      AssistantChat.create!(id: "example", title: "For everyone")
      AssistantChat.create!(id: "adas", title: "Ada's", visitor_id: "ada")
      AssistantChat.create!(id: "bobs", title: "Bob's", visitor_id: "bob")
    end

    test "a bootstrap holds the browser's own chats and the examples" do
      assert_equal %w[adas example], bootstrapped(scope: "ada")
      assert_equal %w[example], bootstrapped({})
    end

    test "the change stream carries the browser's own changes and the examples'" do
      get "/instant_record/events", params: { after: 0, window: 0, scope: "ada" }
      assert_equal %w[adas example], changed

      get "/instant_record/events", params: { after: 0, window: 0 }
      assert_equal %w[example], changed
    end

    test "a question synced up belongs to its sender, and Rails' answer comes back to them alone" do
      perform_enqueued_jobs do
        post "/instant_record/mutations?scope=ada", as: :json, params: { mutations: [
          { id: "m-1", record_type: "AssistantTurn", record_id: "t-1", operation: "create",
            changes: { assistant_chat_id: "adas", prompt: "Explain offline sync", engine: "server", visitor_id: "bob" } }
        ] }
      end

      assert_equal "applied", response.parsed_body.dig("results", 0, "status")
      turn = AssistantTurn.find("t-1")
      assert_equal "ada", turn.visitor_id
      assert_includes turn.reply, "worker sends pending mutations"

      cursor = InstantRecord::Change.where(record_id: "t-1").minimum(:id) - 1
      get "/instant_record/events", params: { after: cursor, window: 0, scope: "ada" }
      assert_equal %w[t-1 t-1], changed
      get "/instant_record/events", params: { after: cursor, window: 0, scope: "bob" }
      assert_empty changed
    end

    test "another browser's chat takes no write" do
      post "/instant_record/mutations?scope=ada", as: :json, params: { mutations: [
        { id: "m-2", record_type: "AssistantChat", record_id: "bobs", operation: "update", changes: { title: "Ada's now" } },
        { id: "m-3", record_type: "AssistantChat", record_id: "bobs", operation: "destroy", changes: {} },
        { id: "m-4", record_type: "AssistantChat", record_id: "example", operation: "update", changes: { title: "Ada's now" } }
      ] }

      assert_equal %w[rejected] * 3, response.parsed_body["results"].map { |result| result["status"] }
      assert_equal ["Bob's", "For everyone"], AssistantChat.where(id: %w[bobs example]).order(:id).pluck(:title)
    end

    private

    def bootstrapped(params)
      get "/instant_record/bootstrap", params: params
      response.parsed_body["records"].select { |record| record["type"] == "AssistantChat" }.map { |record| record["id"] }.sort
    end

    def changed
      response.body.scan(/^data: (.*)$/).map { |(json)| JSON.parse(json) }
        .select { |event| event["type"].start_with?("Assistant") }.map { |event| event["id"] }.sort
    end
  end
end
