require "test_helper"

module Slack
  class MessagesControllerTest < ActionDispatch::IntegrationTest
    setup do
      Slack::Seeds.apply
    end

    test "posting a message persists it with the visitor as author" do
      post slack_messages_url, params: { message: { channel_id: "channel-general", body: "hello swiss" } }

      assert_redirected_to slack_channel_path("channel-general")
      message = Message.find_by!(body: "hello swiss")
      assert_equal ChatUser::VISITOR_ID, message.chat_user_id
    end

    test "a forged author param is ignored" do
      post slack_messages_url, params: {
        message: { channel_id: "channel-general", body: "spoofed", chat_user_id: "bot-ursula" }
      }

      assert_equal ChatUser::VISITOR_ID, Message.find_by!(body: "spoofed").chat_user_id
    end

    test "a blank body creates nothing and redirects back" do
      assert_no_difference -> { Message.count } do
        post slack_messages_url, params: { message: { channel_id: "channel-general", body: "   " } }
      end

      assert_redirected_to slack_channel_path("channel-general")
    end

    test "posted message renders in the channel on the redirected GET" do
      post slack_messages_url, params: { message: { channel_id: "channel-random", body: "grid appreciation post" } }
      follow_redirect!

      assert_includes response.body, "grid appreciation post"
    end
  end
end
