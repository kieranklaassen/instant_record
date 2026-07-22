require "test_helper"

module Slack
  class ResetsControllerTest < ActionDispatch::IntegrationTest
    setup do
      Slack::Seeds.apply
    end

    test "reset removes visitor data, reseeds, and change-logs the destroys" do
      extra = Message.create!(channel_id: "channel-general", chat_user_id: ChatUser::VISITOR_ID, body: "wipe me")
      seed_ids = Slack::Seeds.seed_ids

      post slack_reset_url

      assert_response :no_content
      assert_equal seed_ids[:messages].sort, Message.pluck(:id).sort
      assert_equal seed_ids[:channels].sort, Channel.pluck(:id).sort
      assert_equal seed_ids[:users].sort, ChatUser.pluck(:id).sort
      assert InstantRecord::Change.exists?(record_id: extra.id, operation: "destroy"),
        "destroyed rows must be change-logged so clients converge"
    end

    test "reset is served cross-origin (API controller with CORS headers)" do
      post slack_reset_url

      assert_equal "*", response.headers["access-control-allow-origin"]
    end

    test "reset twice in a row is safe" do
      post slack_reset_url
      post slack_reset_url

      assert_response :no_content
      assert_equal Slack::Seeds.seed_ids[:messages].sort, Message.pluck(:id).sort
    end
  end
end
