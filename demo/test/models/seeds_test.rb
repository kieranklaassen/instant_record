require "test_helper"

class SeedsTest < ActiveSupport::TestCase
  test "seeding twice adds no rows" do
    Slack::Seeds.apply
    counts = [ChatUser.count, Channel.count, Message.count]

    Slack::Seeds.apply

    assert_equal counts, [ChatUser.count, Channel.count, Message.count]
  end

  test "backfill writes deep history without change-log rows" do
    Slack::Seeds.apply
    Message.where("id LIKE 'backfill-%'").delete_all

    assert_no_difference -> { InstantRecord::Change.count } do
      Slack::Seeds.apply_backfill
    end

    expected = Slack::Seeds.backfill_counts.values.sum
    assert_equal expected, Message.where("id LIKE 'backfill-%'").count
    assert_operator expected, :>, 0

    sample = Message.where("id LIKE 'backfill-%'").order(:created_at).first
    assert_equal 1, sample.server_version
    assert_equal "synced", sample.sync_state
    assert_operator sample.created_at, :<, Time.current
  end

  test "backfill sentinel short-circuits the bulk insert per channel" do
    Slack::Seeds.apply

    # Leave only #general's last-row sentinel standing, then reseed: #general
    # is skipped (sentinel present), the other channels backfill again.
    general_sentinel = Slack::Seeds.backfill_id("channel-general", Slack::Seeds.backfill_counts["channel-general"])
    Message.where("id LIKE 'backfill-%'").where.not(id: general_sentinel).delete_all
    Slack::Seeds.apply_backfill

    assert_equal 1, Message.where("id LIKE 'backfill-channel-general-%'").count
    assert_equal Slack::Seeds.backfill_counts["channel-random"],
      Message.where("id LIKE 'backfill-channel-random-%'").count
  end

  test "an interrupted backfill completes on the next run" do
    Slack::Seeds.apply

    # Simulate a crash after the first insert_all slice: the tail is missing
    # and the last-row sentinel is absent, so reseeding fills the gap.
    count = Slack::Seeds.backfill_counts["channel-general"]
    Message.where("id LIKE 'backfill-channel-general-%'")
      .where("id > ?", Slack::Seeds.backfill_id("channel-general", 1)).delete_all
    Slack::Seeds.apply_backfill

    assert_equal count, Message.where("id LIKE 'backfill-channel-general-%'").count
  end
end
