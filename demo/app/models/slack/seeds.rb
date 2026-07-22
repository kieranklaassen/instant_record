# Seed data for the Swiss Slack demo. Fixed ids keep the routine idempotent,
# and the reset endpoint reuses it so "reset" and "fresh install" are the
# same state.
module Slack
  module Seeds
    FAKE_USERS = [
      { id: "bot-ursula", name: "Ursula Grid", handle: "ursula" },
      { id: "bot-max", name: "Max Baseline", handle: "max" },
      { id: "bot-adrian", name: "Adrian Kern", handle: "adrian" },
      { id: "bot-heidi", name: "Heidi Helvetica", handle: "heidi" }
    ].freeze

    CHANNELS = [
      { id: "channel-general", name: "general" },
      { id: "channel-random", name: "random" },
      { id: "channel-design", name: "design" }
    ].freeze

    WELCOME = {
      "channel-general" => ["bot-ursula", "Welcome to #general. Alignment is not optional."],
      "channel-random" => ["bot-max", "Randomness, but on a grid."],
      "channel-design" => ["bot-heidi", "Helvetica. Black. Red. That is the whole palette. Discuss."]
    }.freeze

    module_function

    def apply
      visitor = ChatUser.find_or_create_by!(id: ChatUser::VISITOR_ID) do |u|
        u.name = "You"
        u.handle = "you"
        u.bot = false
      end

      FAKE_USERS.each do |attrs|
        ChatUser.find_or_create_by!(id: attrs[:id]) do |u|
          u.name = attrs[:name]
          u.handle = attrs[:handle]
          u.bot = true
        end
      end

      CHANNELS.each do |attrs|
        Channel.find_or_create_by!(id: attrs[:id]) do |c|
          c.name = attrs[:name]
          c.kind = "channel"
        end
      end

      FAKE_USERS.each do |attrs|
        Channel.find_or_create_by!(id: "dm-#{attrs[:id]}") do |c|
          c.name = attrs[:handle]
          c.kind = "dm"
          c.dm_user_id = attrs[:id]
        end
      end

      WELCOME.each do |channel_id, (user_id, body)|
        Message.find_or_create_by!(id: "welcome-#{channel_id}") do |m|
          m.channel_id = channel_id
          m.chat_user_id = user_id
          m.body = body
        end
      end

      FAKE_USERS.each do |attrs|
        Message.find_or_create_by!(id: "welcome-dm-#{attrs[:id]}") do |m|
          m.channel_id = "dm-#{attrs[:id]}"
          m.chat_user_id = attrs[:id]
          m.body = "This is our DM. Say something and I will reply — even if you post it offline."
        end
      end

      visitor
    end

    def seed_ids
      user_ids = [ChatUser::VISITOR_ID] + FAKE_USERS.map { |u| u[:id] }
      channel_ids = CHANNELS.map { |c| c[:id] } + FAKE_USERS.map { |u| "dm-#{u[:id]}" }
      message_ids = WELCOME.keys.map { |id| "welcome-#{id}" } +
        FAKE_USERS.map { |u| "welcome-dm-#{u[:id]}" }
      { users: user_ids, channels: channel_ids, messages: message_ids }
    end
  end
end
