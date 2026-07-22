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

    # Deep message history so the windowed sync has something to window.
    # Inserted with insert_all: no callbacks, therefore no change-log rows —
    # a logged backfill would make every already-synced client replay
    # thousands of events (KTD7 in the plan). Fresh clients see it because
    # bootstrap reads tables, not the log. The `backfill-` id prefix is
    # load-bearing: reset preserves history by excluding it.
    BACKFILL_SPAN = 21.days
    BACKFILL_LINES = [
      "Alignment is a lifestyle.",
      "White space is not empty space.",
      "The grid abides.",
      "Kerning complaint filed. Again.",
      "Objectivity, neutrality, Helvetica.",
      "A poster without a grid is a cry for help.",
      "Red. But only one red.",
      "Asymmetry, but earned.",
      "Lowercase is a design decision.",
      "Content precedes form. Form complies."
    ].freeze

    module_function

    def backfill_counts
      base = ENV.fetch("SLACK_BACKFILL_MESSAGES") { Rails.env.test? ? 12 : 5000 }.to_i
      {
        "channel-general" => base,
        "channel-random" => base / 10,
        "channel-design" => base / 10
      }
    end

    def backfill_id(channel_id, index)
      "backfill-#{channel_id}-#{format('%05d', index)}"
    end

    def apply
      ChatUser.find_or_create_by!(id: ChatUser::VISITOR_ID) do |u|
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

      apply_backfill
    end

    def apply_backfill
      now = Time.current
      backfill_counts.each do |channel_id, count|
        next if count.zero?
        # Sentinel: the first backfill row existing means this channel's
        # backfill already ran — reseeding and reset skip the bulk insert.
        next if Message.exists?(id: backfill_id(channel_id, 1))

        rows = (1..count).map do |i|
          at = now - BACKFILL_SPAN + (BACKFILL_SPAN * i / (count + 1))
          {
            id: backfill_id(channel_id, i),
            channel_id: channel_id,
            chat_user_id: FAKE_USERS[i % FAKE_USERS.size][:id],
            body: "#{BACKFILL_LINES[i % BACKFILL_LINES.size]} (##{i})",
            server_version: 1,
            sync_state: "synced",
            created_at: at,
            updated_at: at
          }
        end
        rows.each_slice(1_000) { |slice| Message.insert_all(slice) }
      end
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
