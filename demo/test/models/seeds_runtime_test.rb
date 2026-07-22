require "test_helper"

class SeedsRuntimeTest < ActiveSupport::TestCase
  # Regression: the browser runtime runs db/seeds.rb on boot
  # (DatabaseTasks.prepare_all). Seeding there records every row as an outbox
  # mutation and replays seed data at the server. Seeds must be a server-only
  # concern; browsers converge via the downstream change-log sync.
  test "seeds are skipped in the browser runtime" do
    # Force-load the models before stubbing the runtime: server_only blocks
    # are evaluated at class-load time, so autoloading Message inside the
    # browser stub would strip its server-side callbacks for the whole
    # test process.
    [ChatUser, Channel, Message, Slack::Seeds].each(&:name)

    InstantRecord.singleton_class.class_eval do
      alias_method :original_browser?, :browser?
      define_method(:browser?) { true }
    end

    assert_no_difference -> { ChatUser.count + Channel.count + Message.count } do
      Rails.application.load_seed
    end
    assert_equal 0, InstantRecord::OutboxMutation.count
  ensure
    InstantRecord.singleton_class.class_eval do
      remove_method :browser?
      alias_method :browser?, :original_browser?
      remove_method :original_browser?
    end
  end

  test "seeds apply in the server runtime" do
    Rails.application.load_seed

    assert ChatUser.exists?(ChatUser::VISITOR_ID)
    assert Channel.exists?("channel-general")
  end
end
