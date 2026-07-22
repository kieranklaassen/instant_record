require "test_helper"

class MessageTest < ActiveSupport::TestCase
  setup do
    Slack::Seeds.apply
  end

  test "message with valid channel and user persists" do
    message = Message.create!(
      channel_id: "channel-general",
      chat_user_id: ChatUser::VISITOR_ID,
      body: "hello"
    )

    assert message.persisted?
    assert_equal "synced", message.sync_state
  end

  test "message without a body is invalid" do
    message = Message.new(channel_id: "channel-general", chat_user_id: ChatUser::VISITOR_ID)

    refute message.valid?
  end

  test "channel kind is restricted to channel and dm" do
    refute Channel.new(name: "weird", kind: "group").valid?
    assert Channel.new(name: "ok", kind: "channel").valid?
  end

  test "dm channels require a dm partner" do
    refute Channel.new(name: "lonely", kind: "dm").valid?
  end

  test "seeds are idempotent" do
    counts = [ChatUser.count, Channel.count, Message.count]

    Slack::Seeds.apply

    assert_equal counts, [ChatUser.count, Channel.count, Message.count]
  end
end
