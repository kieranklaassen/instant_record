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

    test "a thread reply lands under its parent and returns to the thread" do
      parent = Channel.find("channel-general").messages.top_level.first

      post slack_messages_url, params: {
        message: { channel_id: "channel-general", body: "threaded take", parent_message_id: parent.id }
      }

      assert_redirected_to slack_channel_path("channel-general", thread: parent.id)
      reply = Message.find_by!(body: "threaded take")
      assert_equal parent.id, reply.parent_message_id

      follow_redirect!
      assert_includes response.body, "thread-panel"
      assert_includes response.body, "threaded take"
    end

    test "a reply to a message in another channel is rejected" do
      foreign_parent = Channel.find("channel-random").messages.top_level.first

      assert_no_difference -> { Message.count } do
        post slack_messages_url, params: {
          message: { channel_id: "channel-general", body: "wrong room", parent_message_id: foreign_parent.id }
        }
      rescue ActiveRecord::RecordInvalid
        # Depending on show_exceptions the invalid create either raises here or
        # renders a 500; either way the row must not exist.
      end

      refute Message.exists?(body: "wrong room")
    end

    test "threads do not nest: replying to a reply is rejected" do
      parent = Channel.find("channel-general").messages.top_level.first
      reply = Message.create!(channel_id: "channel-general", chat_user_id: ChatUser::VISITOR_ID,
        body: "first level", parent_message_id: parent.id)

      assert_raises ActiveRecord::RecordInvalid do
        Message.create!(channel_id: "channel-general", chat_user_id: ChatUser::VISITOR_ID,
          body: "second level", parent_message_id: reply.id)
      end
    end

    test "the fake reply to a threaded message stays in the thread" do
      parent = Channel.find("channel-general").messages.top_level.first
      reply = Message.create!(channel_id: "channel-general", chat_user_id: ChatUser::VISITOR_ID,
        body: "ping in thread", parent_message_id: parent.id)

      perform_enqueued_jobs only: Slack::FakeReplyJob

      bot_reply = Message.where(parent_message_id: parent.id).where.not(id: reply.id).first
      assert bot_reply, "the bot must answer in the same thread"
      assert bot_reply.chat_user.bot?
    end

    test "replies stay out of the conversation and count on their parent" do
      parent = Channel.find("channel-general").messages.top_level.first
      Message.create!(channel_id: "channel-general", chat_user_id: ChatUser::VISITOR_ID,
        body: "only in the panel", parent_message_id: parent.id)

      get slack_channel_url("channel-general")

      assert_includes response.body, "1 reply ⟶"
      refute_includes response.body[/<ol class="messages".*<\/ol>/m].to_s, "only in the panel",
        "a reply must not render as a conversation row"
    end
  end
end
