require "test_helper"

class BoundedDrainTest < Minitest::Test
  def setup
    @model = syncable_model("Task")
    InstantRecord.sync(@model)
    @original_batch_size = InstantRecord.config.drain_batch_size
    @original_max_retries = InstantRecord.config.max_server_error_retries
    @notifier = Class.new { def records_changed; end }.new
    InstantRecord::Client.notifier = @notifier
    reset_instant_record_tables!
  end

  def teardown
    InstantRecord.config.drain_batch_size = @original_batch_size
    InstantRecord.config.max_server_error_retries = @original_max_retries
    InstantRecord.sync
    InstantRecord::Client.transport = nil
    InstantRecord::Client.notifier = nil
  end

  def build_transport(&on_post)
    posts = []
    transport = Object.new
    transport.define_singleton_method(:posts) { posts }
    transport.define_singleton_method(:post_json) do |path, payload|
      posts << [path, payload]
      on_post.call(payload)
    end
    transport.define_singleton_method(:get_json) { |_path| { "cursor" => 0, "records" => [] } }
    transport.define_singleton_method(:each_event) { |_path| nil }
    transport
  end

  def test_drain_chunks_large_outbox_by_configured_batch_size
    InstantRecord.config.drain_batch_size = 25
    in_browser do
      60.times { |i| @model.create!(id: format("t-%03d", i), title: "task #{i}") }
    end

    transport = build_transport do |payload|
      { "results" => payload[:mutations].map { |m| { "mutation_id" => m[:id], "status" => "applied", "version" => 1 } } }
    end
    InstantRecord::Client.transport = transport

    in_browser { assert InstantRecord::Client.drain }

    assert_equal [25, 25, 10], transport.posts.map { |(_p, body)| body[:mutations].size }
    assert_equal 0, InstantRecord.pending_count
    assert_equal 0, InstantRecord::Client::Rebaser.confirmed_snapshot_count
  end

  def test_poison_pill_is_isolated_via_bisection_after_n_5xx_retries_without_stalling_queue
    InstantRecord.config.drain_batch_size = 10
    InstantRecord.config.max_server_error_retries = 3

    t0 = Time.utc(2026, 11, 21, 12, 0, 0)
    # Seed a confirmed server row so we verify rollback on poison-pill quarantine too.
    in_browser do
      InstantRecord::Client.apply_change(
        "type" => "Task", "id" => "poison-row", "operation" => "create", "version" => 1,
        "attributes" => { "id" => "poison-row", "title" => "safe server value", "updated_at" => t0.iso8601(6) }
      )
      @model.create!(id: "good-1", title: "good 1")
      @model.create!(id: "good-2", title: "good 2")
      @model.find("poison-row").update!(title: "triggers 500")
      @model.create!(id: "good-3", title: "good 3")
      @model.create!(id: "good-4", title: "good 4")
    end

    poison_id = InstantRecord::OutboxMutation.find_by(record_id: "poison-row").id
    poison_events = []
    sub = ActiveSupport::Notifications.subscribe("poison_pill.instant_record") { |*, payload| poison_events << payload }

    applied_ids = []
    transport = build_transport do |payload|
      ids = payload[:mutations].map { |m| m[:id] }
      if ids.include?(poison_id)
        raise InstantRecord::Client::Transport::Error.new("POST /mutations -> 500", status: 500)
      end
      applied_ids.concat(ids)
      { "results" => ids.map { |id| { "mutation_id" => id, "status" => "applied", "version" => 2 } } }
    end
    InstantRecord::Client.transport = transport

    begin
      # Run drain passes until the queue finishes draining (bounded loop).
      10.times do
        break if InstantRecord.pending_count == 0
        capture_io { in_browser { InstantRecord::Client.drain } }
      end
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    assert_equal 0, InstantRecord.pending_count, "queue must completely drain after isolating the poison pill"
    assert_equal 4, applied_ids.uniq.size, "all 4 healthy mutations must succeed"
    refute_includes applied_ids, poison_id

    quarantined = InstantRecord::Client.quarantined_mutations
    assert_equal [poison_id], quarantined.map { |q| q["mutation_id"] }, "only the poison pill may be quarantined"
    assert_equal 500, quarantined.first["status"]
    assert_equal 3, quarantined.first["attempts"]

    assert_equal 1, poison_events.size
    assert_equal poison_id, poison_events.first[:mutation_id]

    # Quarantined row was rolled back cleanly to its server-confirmed snapshot.
    poison_row = @model.find("poison-row")
    assert_equal "safe server value", poison_row.title
    assert_equal "synced", poison_row.sync_state
    assert_equal 0, InstantRecord::Client::Rebaser.confirmed_snapshot_count
  end

  def test_offline_and_4xx_errors_never_quarantine_mutations
    InstantRecord.config.max_server_error_retries = 2
    in_browser { @model.create!(id: "offline-1", title: "keep me") }

    transport = build_transport do |_payload|
      raise InstantRecord::Client::Transport::Error.new("POST /mutations -> 0", status: 0)
    end
    InstantRecord::Client.transport = transport

    5.times { capture_io { in_browser { InstantRecord::Client.drain } } }
    assert_equal 1, InstantRecord.pending_count
    assert_empty InstantRecord::Client.quarantined_mutations

    transport_429 = build_transport do |_payload|
      raise InstantRecord::Client::Transport::Error.new("POST /mutations -> 429", status: 429)
    end
    InstantRecord::Client.transport = transport_429

    5.times { capture_io { in_browser { InstantRecord::Client.drain } } }
    assert_equal 1, InstantRecord.pending_count
    assert_empty InstantRecord::Client.quarantined_mutations
  end

  def test_transient_5xx_below_threshold_recovers_without_quarantine
    InstantRecord.config.max_server_error_retries = 3
    in_browser { @model.create!(id: "flaky-1", title: "recovers") }

    attempts = 0
    transport = build_transport do |payload|
      attempts += 1
      raise InstantRecord::Client::Transport::Error.new("POST /mutations -> 503", status: 503) if attempts <= 2

      { "results" => payload[:mutations].map { |m| { "mutation_id" => m[:id], "status" => "applied", "version" => 1 } } }
    end
    InstantRecord::Client.transport = transport

    3.times { capture_io { in_browser { InstantRecord::Client.drain } } }

    assert_equal 0, InstantRecord.pending_count
    assert_empty InstantRecord::Client.quarantined_mutations
    assert_equal "synced", @model.find("flaky-1").sync_state
  end

  def test_apply_prepared_sync_merges_acks_by_mutation_id_while_newer_local_edits_arrive
    InstantRecord.config.drain_batch_size = 5
    in_browser do
      @model.create!(id: "r-1", title: "v1")
      @model.create!(id: "r-2", title: "v1")
    end

    # Worker plans batch 1 and sends it over the network...
    batch1 = InstantRecord::Client.drain_batch
    sent_ids = batch1.map { |m| m[:id] }

    # ...while the POST is in flight, the user rapidly clicks and adds newer local edits!
    in_browser do
      @model.find("r-1").update!(title: "v2-during-flight")
      @model.create!(id: "r-3", title: "new-during-flight")
    end

    # Server responds to batch 1. Prepared sync merges by mutation_id without discarding acks!
    results = sent_ids.map { |id| { "mutation_id" => id, "status" => "applied", "version" => 1 } }
    outcome = in_browser do
      InstantRecord::Client.apply_prepared_sync(
        push: { status: 200, body: JSON.generate({ results: results }), mutation_ids: sent_ids }
      )
    end

    assert outcome[:changed]
    assert outcome[:progressed]
    refute outcome[:failed]

    # Batch 1 acked & removed; newer edits remain intact and pending!
    assert_equal 2, InstantRecord.pending_count
    remaining_record_ids = InstantRecord::OutboxMutation.ordered.pluck(:record_id)
    assert_equal %w[r-1 r-3], remaining_record_ids

    r1 = @model.find("r-1")
    assert_equal "v2-during-flight", r1.title
    assert_equal "pending", r1.sync_state
    assert_equal 1, r1.server_version

    r2 = @model.find("r-2")
    assert_equal "synced", r2.sync_state
    assert_equal 1, r2.server_version
  end

  def test_rapid_concurrency_prepared_sync_never_livelocks_or_replays_acked_ids
    InstantRecord.config.drain_batch_size = 3
    sent_history = Hash.new(0)

    in_browser { @model.create!(id: "click-0", title: "click 0") }

    # Simulate 15 rounds where every time a POST is in flight, a new click lands before the response returns.
    15.times do |round|
      batch = InstantRecord::Client.drain_batch
      refute_empty batch
      ids = batch.map { |m| m[:id] }
      ids.each { |id| sent_history[id] += 1 }

      # Concurrent click lands during RTT for the first 10 rounds.
      if round < 10
        in_browser { @model.create!(id: "click-#{round + 1}", title: "click #{round + 1}") }
      end

      results = ids.map { |id| { "mutation_id" => id, "status" => "applied", "version" => 1 } }
      outcome = in_browser do
        InstantRecord::Client.apply_prepared_sync(
          push: { status: 200, body: JSON.generate({ results: results }), mutation_ids: ids }
        )
      end

      assert outcome[:progressed], "round #{round} must make forward progress despite concurrent clicks"
      break if InstantRecord.pending_count == 0
    end

    assert_equal 0, InstantRecord.pending_count, "all 11 rapid clicks must drain without livelock"
    assert_equal 11, @model.count
    assert sent_history.values.all? { |count| count == 1 },
      "no mutation should be redundantly replayed: #{sent_history.inspect}"
    assert_equal 0, InstantRecord::Client::Rebaser.confirmed_snapshot_count
  end

  def test_apply_prepared_sync_handles_malformed_json_as_retryable_failure
    in_browser { @model.create!(id: "bad-json-1", title: "keep") }
    sent_ids = InstantRecord::Client.drain_batch.map { |m| m[:id] }

    outcome = capture_io do
      @result = in_browser do
        InstantRecord::Client.apply_prepared_sync(
          push: { status: 200, body: "<html>gateway error</html>", mutation_ids: sent_ids }
        )
      end
    end

    assert @result[:failed]
    refute @result[:progressed]
    assert_equal 1, InstantRecord.pending_count
    assert_empty InstantRecord::Client.quarantined_mutations
  end
end
