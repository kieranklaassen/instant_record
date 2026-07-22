require "test_helper"

module Slack
  class ChannelsControllerTest < ActionDispatch::IntegrationTest
    setup do
      Slack::Seeds.apply
    end

    test "slack root redirects to #general" do
      get slack_root_url

      assert_redirected_to slack_channel_path("channel-general")
    end

    test "show renders the seeded welcome message and the server_only marker" do
      get slack_channel_url("channel-general")

      assert_response :success
      assert_includes response.body, "Alignment is not optional."
      assert_equal "server", response.headers["x-instant-record-runtime"]
    end

    test "show lists channels, dms, and users in the sidebar" do
      get slack_channel_url("channel-general")

      assert_includes response.body, "#random"
      assert_includes response.body, "Heidi Helvetica"
      assert_includes response.body, "(you)"
    end

    test "unknown channel 404s" do
      get slack_channel_url("nope")

      assert_response :not_found
    end

    def create_history(count, channel: "channel-general", base: 500.minutes.ago)
      count.times do |i|
        at = base + i.minutes
        Message.create!(id: "hist-#{format('%03d', i)}", channel_id: channel,
          chat_user_id: "bot-max", body: "history #{i}", created_at: at, updated_at: at)
      end
    end

    def rendered_message_ids
      response.body.scan(/data-id="([^"]+)"/).flatten
    end

    def oldest_cursor
      [response.body[/data-oldest-created-at="([^"]+)"/, 1],
        response.body[/data-oldest-id="([^"]+)"/, 1]]
    end

    test "show renders only the newest window with its cursor attributes" do
      create_history(200)

      get slack_channel_url("channel-general")

      ids = rendered_message_ids
      assert_equal 50, ids.size
      assert_equal "welcome-channel-general", ids.last, "display order is ascending — newest last"
      assert_equal "hist-151", ids.first, "the 50th-newest row is the floor"
      at, id = oldest_cursor
      assert_equal "hist-151", id
      assert_equal Message.find("hist-151").created_at.utc.iso8601(6), at
      assert_includes response.body, 'data-has-more="true"'
      refute_includes response.body, "data-beginning"
    end

    test "an explicit floor renders everything from that keyset to newest" do
      create_history(80)
      floor = Message.find("hist-020")

      get slack_channel_url("channel-general",
        floor_created_at: floor.created_at.utc.iso8601(6), floor_id: floor.id)

      ids = rendered_message_ids
      assert_equal "hist-020", ids.first, "floor row is inclusive"
      assert_equal 61, ids.size # hist-020..hist-079 plus the welcome message
    end

    test "deepen extends the floor by one page" do
      create_history(200)
      floor = Message.find("hist-151")

      get slack_channel_url("channel-general",
        floor_created_at: floor.created_at.utc.iso8601(6), floor_id: floor.id, deepen: 1)

      ids = rendered_message_ids
      assert_equal 100, ids.size
      assert_equal "hist-101", ids.first
    end

    test "fragment renders the messages partial without layout" do
      get slack_channel_url("channel-general", fragment: 1)

      assert_response :success
      assert_includes response.body, 'class="messages"'
      refute_includes response.body, "<html", "fragment must not carry the layout"
      refute_includes response.body, "sidebar"
    end

    test "a floor deeper than the clamp renders at most the max depth on the server" do
      create_history(300)
      floor = Message.find("hist-000")

      get slack_channel_url("channel-general",
        floor_created_at: floor.created_at.utc.iso8601(6), floor_id: floor.id)

      assert_equal Slack::ChannelsController::MAX_RENDER_DEPTH, rendered_message_ids.size
      assert_equal "welcome-channel-general", rendered_message_ids.last,
        "the clamp drops the floor end, never the live end"
    end

    test "beginning of channel renders when the floor reaches the start" do
      # Fresh DM with a single seeded message — the whole history fits.
      get slack_channel_url("dm-bot-ursula")

      assert_includes response.body, 'data-has-more="false"'
      assert_includes response.body, "data-beginning"
      assert_includes response.body, "Beginning of this conversation"
    end

    test "an unparseable floor falls back to the default window" do
      create_history(60)

      get slack_channel_url("channel-general", floor_created_at: "garbage", floor_id: "x")

      assert_response :success
      assert_equal 50, rendered_message_ids.size
    end

    test "an empty channel renders an empty list without errors" do
      empty = Channel.create!(id: "channel-empty", name: "void", kind: "channel")

      get slack_channel_url(empty)

      assert_response :success
      assert_empty rendered_message_ids
      assert_includes response.body, 'data-has-more="false"'
    end

    test "keyset pagination across a boundary yields no duplicates or gaps" do
      create_history(120)

      get slack_channel_url("channel-general")
      first_ids = rendered_message_ids
      at, id = oldest_cursor

      get slack_channel_url("channel-general", floor_created_at: at, floor_id: id, deepen: 1)
      second_ids = rendered_message_ids

      assert_equal (second_ids & first_ids).sort, first_ids.sort, "deepened render keeps every prior row"
      assert_equal 100, second_ids.size, "exactly one more page, no gaps"
    end
  end
end
