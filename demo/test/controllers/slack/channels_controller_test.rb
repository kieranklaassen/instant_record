require "test_helper"

module Slack
  class ChannelsControllerTest < ActionDispatch::IntegrationTest
    setup do
      Slack::Seeds.apply
    end

    test "slack root redirects to the first channel" do
      get slack_root_url

      assert_redirected_to slack_channel_path(Channel.channels.first)
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
  end
end
