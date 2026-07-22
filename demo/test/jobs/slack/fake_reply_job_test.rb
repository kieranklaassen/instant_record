require "test_helper"

module Slack
  class FakeReplyJobTest < ActiveJob::TestCase
    setup do
      Slack::Seeds.apply
    end

    test "visitor message in a channel enqueues a fake reply" do
      assert_enqueued_with(job: Slack::FakeReplyJob) do
        Message.create!(channel_id: "channel-general", chat_user_id: ChatUser::VISITOR_ID, body: "anyone here?")
      end
    end

    test "bot-authored message enqueues nothing (no reply loops)" do
      assert_no_enqueued_jobs(only: Slack::FakeReplyJob) do
        Message.create!(channel_id: "channel-general", chat_user_id: "bot-ursula", body: "beep")
      end
    end

    test "performing the job creates a bot reply in the same channel" do
      message = Message.create!(channel_id: "channel-random", chat_user_id: ChatUser::VISITOR_ID, body: "hello")

      assert_difference -> { Message.where(channel_id: "channel-random").count }, 1 do
        Slack::FakeReplyJob.perform_now(message.id)
      end

      reply = Message.where(channel_id: "channel-random").order(:created_at).last
      assert ChatUser.find(reply.chat_user_id).bot?
    end

    test "dm reply is authored by exactly the dm partner" do
      message = Message.create!(channel_id: "dm-bot-max", chat_user_id: ChatUser::VISITOR_ID, body: "hi max")

      Slack::FakeReplyJob.perform_now(message.id)

      reply = Message.where(channel_id: "dm-bot-max").order(:created_at).last
      assert_equal "bot-max", reply.chat_user_id
    end

    test "job is a no-op when the message was deleted before it ran" do
      message = Message.create!(channel_id: "channel-general", chat_user_id: ChatUser::VISITOR_ID, body: "gone soon")
      Message.where(id: message.id).delete_all

      assert_nothing_raised do
        assert_no_difference -> { Message.count } do
          Slack::FakeReplyJob.perform_now(message.id)
        end
      end
    end
  end
end
