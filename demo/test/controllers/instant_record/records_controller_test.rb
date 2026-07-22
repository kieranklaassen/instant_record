require "test_helper"

module InstantRecord
  class RecordsControllerTest < ActionDispatch::IntegrationTest
    setup do
      Slack::Seeds.apply
    end

    def create_messages(count, channel: "channel-general", base: 90.minutes.ago)
      count.times do |i|
        at = base + i.minutes
        Message.create!(id: "hist-#{format('%03d', i)}", channel_id: channel,
          chat_user_id: "bot-max", body: "history #{i}", created_at: at, updated_at: at)
      end
    end

    def fetch_page(before_at:, before_id:, limit: nil, channel: "channel-general")
      params = { type: "Message", partition: channel,
                 before_created_at: before_at.iso8601(6), before_id: before_id }
      params[:limit] = limit if limit
      get "/instant_record/records", params: params
      JSON.parse(response.body)
    end

    test "pages across a boundary with no duplicates or gaps" do
      create_messages(10)
      newest = Message.where(channel_id: "channel-general").order(created_at: :desc, id: :desc).first

      first_page = fetch_page(before_at: newest.created_at, before_id: newest.id, limit: 4)
      assert first_page["has_more"]
      assert_equal 4, first_page["records"].size

      oldest = first_page["records"].last
      second_page = fetch_page(before_at: Time.zone.parse(oldest["attributes"]["created_at"]),
        before_id: oldest["id"], limit: 4)

      ids = (first_page["records"] + second_page["records"]).map { |r| r["id"] }
      assert_equal ids.uniq, ids, "boundary rows must not duplicate across pages"
      assert_equal 8, ids.size, "boundary rows must not vanish between pages"
    end

    test "microsecond-identical timestamps break ties by id without loss" do
      tie = Time.zone.now.change(usec: 123_456)
      %w[tie-a tie-b tie-c].each do |id|
        Message.create!(id: id, channel_id: "channel-random", chat_user_id: "bot-max",
          body: id, created_at: tie, updated_at: tie)
      end

      page = fetch_page(before_at: tie, before_id: "tie-c", limit: 1, channel: "channel-random")
      assert_equal "tie-b", page["records"].sole["id"]

      page = fetch_page(before_at: tie, before_id: "tie-b", limit: 1, channel: "channel-random")
      assert_equal "tie-a", page["records"].sole["id"]
    end

    test "limit is clamped to the hard maximum" do
      create_messages(3)

      fetch_page(before_at: Time.zone.now, before_id: "zzz", limit: 100_000)

      assert_response :success
      # 3 history rows + 1 welcome seed; a runaway limit must not error or 500
      assert_operator JSON.parse(response.body)["records"].size, :<=, InstantRecord::RecordsController::HARD_LIMIT
    end

    test "rows carry server_version and never sync_state" do
      create_messages(1)

      page = fetch_page(before_at: Time.zone.now, before_id: "zzz")
      row = page["records"].first

      assert_equal row["attributes"]["server_version"], row["version"]
      refute row["attributes"].key?("sync_state")
    end

    test "unknown type is not found" do
      get "/instant_record/records", params: { type: "Nope", before_created_at: Time.zone.now.iso8601(6), before_id: "x" }
      assert_response :not_found
    end

    test "windowless syncable type is unprocessable" do
      get "/instant_record/records", params: { type: "Issue", before_created_at: Time.zone.now.iso8601(6), before_id: "x" }
      assert_response :unprocessable_entity
    end

    test "missing partition for a partitioned window is a bad request" do
      get "/instant_record/records", params: { type: "Message", before_created_at: Time.zone.now.iso8601(6), before_id: "x" }
      assert_response :bad_request
    end

    test "unparseable keyset is a bad request" do
      get "/instant_record/records", params: { type: "Message", partition: "channel-general",
                                               before_created_at: "not a time", before_id: "x" }
      assert_response :bad_request
    end

    test "response carries CORS headers" do
      fetch_page(before_at: Time.zone.now, before_id: "zzz")
      assert_equal "*", response.headers["access-control-allow-origin"]
    end
  end
end
