require "test_helper"

module InstantRecord
  class BootstrapsControllerTest < ActionDispatch::IntegrationTest
    setup do
      Slack::Seeds.apply
    end

    test "serves the change-log cursor plus current state, windowed per declaration" do
      55.times do |i|
        Message.create!(id: "bulk-#{format('%03d', i)}", channel_id: "channel-general",
          chat_user_id: "bot-ursula", body: "backlog #{i}",
          created_at: (200 - i).minutes.ago, updated_at: (200 - i).minutes.ago)
      end

      get "/instant_record/bootstrap"

      assert_response :success
      payload = JSON.parse(response.body)

      assert_equal InstantRecord::Change.maximum(:id), payload["cursor"]

      general = payload["records"].select do |r|
        r["type"] == "Message" && r["attributes"]["channel_id"] == "channel-general"
      end
      assert_equal 50, general.size, "windowed model contributes only the newest window per partition"
      general_ids = general.map { |r| r["id"] }
      refute_includes general_ids, "bulk-000", "oldest rows fall outside the window"
      assert_includes general_ids, "welcome-channel-general", "newest rows are inside the window"

      assert_equal Channel.count, payload["records"].count { |r| r["type"] == "Channel" },
        "windowless models serialize fully"
      assert_equal ChatUser.count, payload["records"].count { |r| r["type"] == "ChatUser" }
    end

    test "payload rows follow the change-event convention" do
      get "/instant_record/bootstrap"

      payload = JSON.parse(response.body)
      row = payload["records"].find { |r| r["type"] == "Message" }

      assert_equal row["attributes"]["server_version"], row["version"]
      refute row["attributes"].key?("sync_state"), "sync_state is client-local and never serialized"
    end

    test "response carries CORS headers for the cross-origin PWA" do
      get "/instant_record/bootstrap"

      assert_equal "*", response.headers["access-control-allow-origin"]
    end

    test "empty database yields cursor 0 and no records" do
      Message.delete_all
      Channel.delete_all
      ChatUser.delete_all
      Issue.delete_all
      InstantRecord::Change.delete_all

      get "/instant_record/bootstrap"

      payload = JSON.parse(response.body)
      assert_equal 0, payload["cursor"]
      assert_empty payload["records"]
    end
  end
end
