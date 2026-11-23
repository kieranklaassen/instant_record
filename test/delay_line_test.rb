require "test_helper"
require "instant_record/compiler/entry_builder"
require "tmpdir"

class DelayLineTest < Minitest::Test
  class StubTransport
    attr_reader :posts
    attr_accessor :results

    def initialize
      @posts = []
      @results = []
    end

    def post_json(path, payload)
      @posts << [path, payload]
      { "results" => @results }
    end

    def get_json(_path) = { "cursor" => 0, "records" => [] }
    def each_event(_path) = nil
  end

  class StubNotifier
    attr_reader :notifications
    def initialize = @notifications = 0
    def records_changed = @notifications += 1
  end

  def setup
    @model = syncable_model("Note")
    InstantRecord.sync(@model)
    @transport = StubTransport.new
    @notifier = StubNotifier.new
    InstantRecord::Client.transport = @transport
    InstantRecord::Client.notifier = @notifier
    reset_instant_record_tables!
    InstantRecord.instance_variable_set(:@started, false)
  end

  def teardown
    InstantRecord.sync
    InstantRecord::Client.transport = nil
    InstantRecord::Client.notifier = nil
    InstantRecord.instance_variable_set(:@started, false)
  end

  # --- Recording held mutations & rollback snapshots -------------------------

  def test_hold_for_attribute_on_create_sets_release_at_and_nil_rollback_payload
    before = Time.now.utc
    note = in_browser { @model.create!(title: "draft", hold_for: 5) }

    mutation = InstantRecord::OutboxMutation.sole
    assert_equal mutation.id, note.last_outbox_mutation_id
    assert_equal "create", mutation.operation
    assert_operator mutation.release_at, :>=, before + 4.5
    assert_operator mutation.release_at, :<=, Time.now.utc + 5.5
    assert_nil mutation.rollback_payload
    assert mutation.held?
    refute mutation.matured?

    # Wire payload never exposes client-local hold fields.
    refute_includes mutation.as_mutation.keys, :release_at
    refute_includes mutation.as_mutation.keys, :rollback_payload
  end

  def test_hold_for_on_update_captures_pre_mutation_snapshot_including_sync_state_and_microseconds
    original_at = Time.utc(2026, 11, 21, 10, 0, 0, 123_456)
    note = on_server { @model.create!(title: "original", state: "open") }
    note.update_columns(server_version: 4, sync_state: "synced", updated_at: original_at)

    in_browser { note.update!(title: "edited", state: "archived", hold_for: 5) }

    mutation = InstantRecord::OutboxMutation.sole
    assert_equal "update", mutation.operation
    assert_equal 4, mutation.base_version
    assert mutation.held?
    assert_equal "original", mutation.rollback_payload["title"]
    assert_equal "open", mutation.rollback_payload["state"]
    assert_equal "synced", mutation.rollback_payload["sync_state"]
    assert_equal 4, mutation.rollback_payload["server_version"]
    assert_equal original_at.iso8601(6), mutation.rollback_payload["updated_at"]
  end

  def test_hold_for_on_destroy_captures_full_pre_destroy_snapshot
    original_at = Time.utc(2026, 11, 21, 11, 0, 0, 654_321)
    note = on_server { @model.create!(title: "keep me", state: "pinned") }
    note.update_columns(server_version: 2, sync_state: "synced", created_at: original_at, updated_at: original_at)

    in_browser { note.destroy!(hold_for: 5) }

    refute @model.exists?(note.id)
    mutation = InstantRecord::OutboxMutation.sole
    assert_equal "destroy", mutation.operation
    assert_equal mutation.id, note.last_outbox_mutation_id
    assert mutation.held?
    assert_equal note.id, mutation.rollback_payload["id"]
    assert_equal "keep me", mutation.rollback_payload["title"]
    assert_equal "pinned", mutation.rollback_payload["state"]
    assert_equal "synced", mutation.rollback_payload["sync_state"]
    assert_equal 2, mutation.rollback_payload["server_version"]
    assert_equal original_at.iso8601(6), mutation.rollback_payload["created_at"]
  end

  def test_block_hold_for_applies_to_all_writes_in_scope_and_restores_nesting
    in_browser do
      InstantRecord.hold_for(10) do
        @model.create!(title: "outer-1")
        InstantRecord.hold_for(0) do
          @model.create!(title: "inner-immediate")
        end
        @model.create!(title: "outer-2")
      end
      @model.create!(title: "after-block")
    end

    mutations = InstantRecord::OutboxMutation.ordered.to_a
    assert_equal 4, mutations.size
    assert mutations[0].held?
    assert_nil mutations[1].release_at
    assert mutations[2].held?
    assert_nil mutations[3].release_at
  end

  def test_hold_for_does_not_leak_onto_subsequent_writes_or_after_rollback
    validated_model = syncable_model("CheckedNote") do
      validates :title, presence: true
    end
    InstantRecord.sync(validated_model)

    in_browser do
      note = validated_model.create!(title: "v1")
      InstantRecord::OutboxMutation.delete_all

      refute note.update(title: "", hold_for: 5)
      note.update!(title: "v2")
    end

    mutation = InstantRecord::OutboxMutation.sole
    assert_nil mutation.release_at, "failed save must not leak hold_for onto the next write"

    in_browser do
      note = validated_model.sole
      InstantRecord::OutboxMutation.delete_all
      note.update!(title: "v3", hold_for: 5)
      note.update!(title: "v4")
    end

    first, second = InstantRecord::OutboxMutation.ordered.to_a
    assert first.held?
    assert_nil second.release_at, "consumed hold_for must not leak onto the next write"
  end

  def test_negative_hold_for_raises_argument_error
    assert_raises(ArgumentError) { InstantRecord.hold_for(-1) { nil } }
    assert_raises(ArgumentError) { in_browser { @model.create!(title: "bad", hold_for: -2) } }
  end

  def test_normal_write_leaves_release_at_and_rollback_payload_nil
    in_browser { @model.create!(title: "immediate") }

    mutation = InstantRecord::OutboxMutation.sole
    assert_nil mutation.release_at
    assert_nil mutation.rollback_payload
    assert mutation.matured?
    refute mutation.held?
  end

  def test_hold_for_is_harmless_on_server_runtime
    note = on_server { @model.create!(title: "server", hold_for: 5) }

    assert_equal 0, InstantRecord::OutboxMutation.count
    assert_equal "synced", note.sync_state
  end

  # --- Filtering pending_mutations & delay-line maturity ---------------------

  def test_pending_mutations_filters_out_unmatured_rows_and_drains_when_matured
    in_browser do
      @model.create!(title: "held", hold_for: 5)
      @model.create!(title: "immediate")
    end

    now = Time.now.utc
    ready = InstantRecord::Client.pending_mutations(now)
    assert_equal 1, ready.size
    assert_equal "immediate", ready.first[:changes]["title"]
    assert_equal 1, InstantRecord::Client.pending_count(now)
    assert_equal 1, InstantRecord::Client.held_count(now)
    assert_equal 1, InstantRecord::Client.held_mutations(now).size

    # Once release_at passes, both are matured.
    future = now + 6
    assert_equal 2, InstantRecord::Client.pending_mutations(future).size
    assert_equal 2, InstantRecord::Client.pending_count(future)
    assert_equal 0, InstantRecord::Client.held_count(future)
    assert_nil InstantRecord::Client.next_release_at(future)
    assert_nil InstantRecord::Client.next_release_ms(future)
  end

  def test_drain_posts_only_matured_mutations_and_leaves_held_rows_in_outbox
    in_browser do
      @model.create!(title: "held", hold_for: 5)
      immediate = @model.create!(title: "immediate")
      @transport.results = [{ "mutation_id" => immediate.last_outbox_mutation_id, "status" => "applied", "version" => 1 }]

      InstantRecord.start
      InstantRecord.tick
    end

    assert_equal 1, @transport.posts.size
    posted = @transport.posts.sole.last[:mutations]
    assert_equal 1, posted.size
    assert_equal "immediate", posted.first[:changes]["title"]
    assert_equal 0, InstantRecord.pending_count
    assert_equal 1, InstantRecord.held_count
  end

  def test_later_unheld_write_on_same_record_waits_behind_earlier_held_write_without_blocking_other_records
    note_a = nil
    note_b = nil
    in_browser do
      note_a = @model.create!(title: "a-create", hold_for: 5)
      note_a.update!(title: "a-update")
      note_b = @model.create!(title: "b-immediate")
    end

    now = Time.now.utc
    ready = InstantRecord::Client.pending_mutations(now)
    assert_equal [note_b.id], ready.map { |m| m[:record_id] },
      "a-update must wait behind held a-create, while independent record b drains immediately"
    assert_equal 1, InstantRecord::Client.pending_count(now)

    # After release_at matures, a-create and a-update are both ready in insertion order.
    future = now + 6
    matured = InstantRecord::Client.pending_mutations(future)
    assert_equal %w[create update create], matured.map { |m| m[:operation] }
  end

  def test_next_release_ms_reports_earliest_held_delay_and_clamps_to_32_bit_safe_ceiling
    now = Time.utc(2026, 11, 21, 12, 0, 0)
    in_browser do
      @model.create!(title: "later", hold_for: 10)
      @model.create!(title: "sooner", hold_for: 3)
    end
    later, sooner = InstantRecord::OutboxMutation.ordered.to_a
    later.update_columns(release_at: now + 10)
    sooner.update_columns(release_at: now + 3)

    assert_equal now + 3, InstantRecord::Client.next_release_at(now)
    assert_equal 3000, InstantRecord::Client.next_release_ms(now)

    # Very far future release_at clamps to MAX_RELEASE_DELAY_MS (fits in wasm32 int32).
    sooner.update_columns(release_at: now + 365 * 86_400)
    later.update_columns(release_at: now + 365 * 86_400)
    assert_equal InstantRecord::Client::MAX_RELEASE_DELAY_MS, InstantRecord::Client.next_release_ms(now)
  end

  # --- Compensating cancel_pending -------------------------------------------

  def test_cancel_pending_reverts_held_create_and_deletes_outbox_row_without_enqueueing
    note = in_browser { @model.create!(title: "undo create", hold_for: 5) }
    mutation_id = note.last_outbox_mutation_id

    cancelled = in_browser { InstantRecord.cancel_pending(mutation_id) }

    assert cancelled
    refute @model.exists?(note.id)
    assert_equal 0, InstantRecord::OutboxMutation.count
  end

  def test_cancel_pending_reverts_held_update_to_exact_pre_mutation_state
    original_at = Time.utc(2026, 11, 21, 9, 30, 0, 246_810)
    note = on_server { @model.create!(title: "before", state: "open") }
    note.update_columns(server_version: 7, sync_state: "synced", updated_at: original_at)

    in_browser { note.update!(title: "after", state: "archived", hold_for: 5) }
    mutation_id = note.last_outbox_mutation_id

    assert_equal "after", note.reload.title
    assert_equal "pending", note.sync_state

    cancelled = in_browser { InstantRecord.cancel_pending(mutation_id) }

    assert cancelled
    assert_equal 0, InstantRecord::OutboxMutation.count
    note.reload
    assert_equal "before", note.title
    assert_equal "open", note.state
    assert_equal "synced", note.sync_state
    assert_equal 7, note.server_version
    assert_equal original_at, note.updated_at
  end

  def test_cancel_pending_reverts_held_destroy_by_reinserting_exact_row
    original_at = Time.utc(2026, 11, 21, 8, 15, 0, 135_791)
    note = on_server { @model.create!(title: "archived mail", state: "inbox") }
    note.update_columns(server_version: 3, sync_state: "synced", created_at: original_at, updated_at: original_at)
    id = note.id

    in_browser { note.destroy!(hold_for: 5) }
    mutation_id = note.last_outbox_mutation_id
    refute @model.exists?(id)

    cancelled = in_browser { InstantRecord.cancel_pending(mutation_id) }

    assert cancelled
    assert_equal 0, InstantRecord::OutboxMutation.count
    restored = @model.find(id)
    assert_equal "archived mail", restored.title
    assert_equal "inbox", restored.state
    assert_equal "synced", restored.sync_state
    assert_equal 3, restored.server_version
    assert_equal original_at, restored.created_at
    assert_equal original_at, restored.updated_at
  end

  def test_cancel_pending_refuses_matured_unheld_unknown_and_already_drained_mutations
    unheld = in_browser { @model.create!(title: "no hold") }
    refute in_browser { InstantRecord.cancel_pending(unheld.last_outbox_mutation_id) }
    refute in_browser { InstantRecord.cancel_pending("nonexistent-id") }

    held = in_browser { @model.create!(title: "matured", hold_for: 5) }
    mutation_id = held.last_outbox_mutation_id
    InstantRecord::OutboxMutation.find(mutation_id).update_columns(release_at: Time.now.utc - 1)

    refute in_browser { InstantRecord.cancel_pending(mutation_id) },
      "matured mutations may already be in flight and must not be cancelled"
    assert @model.exists?(held.id)
  end

  def test_cancel_pending_enforces_lifo_order_on_same_record
    note = on_server { @model.create!(title: "v1") }
    note.update_columns(sync_state: "synced")

    in_browser do
      note.update!(title: "v2", hold_for: 5)
      @m1 = note.last_outbox_mutation_id
      note.update!(title: "v3", hold_for: 5)
      @m2 = note.last_outbox_mutation_id
    end

    # Cannot undo older m1 while newer m2 still sits on top of it.
    refute in_browser { InstantRecord.cancel_pending(@m1) }
    assert_equal "v3", note.reload.title

    # Undoing newest first (m2) restores v2 and keeps sync_state pending for m1.
    assert in_browser { InstantRecord.cancel_pending(@m2) }
    note.reload
    assert_equal "v2", note.title
    assert_equal "pending", note.sync_state

    # Now m1 is top of stack and undoing it restores v1 and synced state.
    assert in_browser { InstantRecord.cancel_pending(@m1) }
    note.reload
    assert_equal "v1", note.title
    assert_equal "synced", note.sync_state
    assert_equal 0, InstantRecord::OutboxMutation.count
  end

  def test_cancel_pending_reconciles_sync_state_when_earlier_mutation_acked_during_hold
    note = in_browser { @model.create!(title: "v1") }
    create_id = note.last_outbox_mutation_id

    in_browser { note.update!(title: "v2", hold_for: 5) }
    update_id = note.last_outbox_mutation_id

    # Earlier create drains and is acked while the subsequent update is still held.
    in_browser do
      InstantRecord::Client.apply_results([{ "mutation_id" => create_id, "status" => "applied", "version" => 1 }])
    end

    note.reload
    assert_equal 1, note.server_version
    assert_equal "pending", note.sync_state, "held update is still unsynced"

    # Now cancel the held update: row reverts to v1 and becomes synced at version 1.
    assert in_browser { InstantRecord.cancel_pending(update_id) }
    note.reload
    assert_equal "v1", note.title
    assert_equal "synced", note.sync_state
    assert_equal 1, note.server_version
    assert_equal 0, InstantRecord::OutboxMutation.count
  end

  def test_tick_json_reports_next_release_ms_when_mutations_are_held
    in_browser do
      @model.create!(title: "held", hold_for: 5)
      InstantRecord.start
      reply = JSON.parse(InstantRecord.tick_json)

      assert_equal true, reply["ok"]
      assert_equal 0, reply["pending"]
      assert_kind_of Integer, reply["next_release_ms"]
      assert_operator reply["next_release_ms"], :>, 0
      assert_operator reply["next_release_ms"], :<=, 5000
    end
  end

  def test_entry_builder_emits_held_and_next_release_ms_in_bridge
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "main.rb"), "require_relative 'boot'\nif ARGV.length > 0 && ARGV[0] == \"sidekiq\"\nend\n")
      InstantRecord::Compiler::EntryBuilder.write_wasm_entry(
        emit_dir: dir,
        demo: false,
        models: ["Note"],
        migration_plan: { "version" => 1, "baseline" => nil, "migrations" => {} },
        pipeline_dir: File.expand_path("../compiled/pipeline", __dir__)
      )

      main = File.read(File.join(dir, "main_wasm.rb"))
      assert_includes main, "InstantRecord::Client.plan_drain"
      assert_includes main, "InstantRecord::Client.clear_planned_drain"
      assert_includes main, "InstantRecord::Client.next_release_ms"
      assert_includes main, "InstantRecord::Client.held_count"
      assert_includes main, "next_release_ms="
    end
  end

  def test_plan_drain_pins_batch_so_mid_fetch_maturation_cannot_cause_mismatch
    in_browser do
      m1 = @model.create!(title: "immediate")
      m2 = @model.create!(title: "maturing-mid-fetch", hold_for: 5)
      @transport.results = [{ "mutation_id" => m1.last_outbox_mutation_id, "status" => "applied", "version" => 1 }]

      planned = InstantRecord::Client.plan_drain
      assert_equal [m1.last_outbox_mutation_id], planned.map { |m| m[:id] }

      # Simulate m2 maturing while the POST for m1 is in flight.
      InstantRecord::OutboxMutation.find(m2.last_outbox_mutation_id).update_columns(release_at: Time.now.utc - 1)

      InstantRecord::Client.drain
      assert_equal 1, @transport.posts.size
      assert_equal [m1.last_outbox_mutation_id], @transport.posts.sole.last[:mutations].map { |m| m[:id] }
      # m2 stays pending for the next pass instead of mismatching the prepared response.
      assert_equal 1, InstantRecord.pending_count
    end
  ensure
    InstantRecord::Client.clear_planned_drain
  end

  def test_cancel_pending_does_not_clobber_concurrent_remote_update_or_resurrect_remote_destroy
    note = on_server { @model.create!(title: "v1") }
    note.update_columns(server_version: 1, sync_state: "synced")

    in_browser { note.update!(title: "local-held", hold_for: 5) }
    mutation_id = note.last_outbox_mutation_id

    # A strictly newer remote update lands during the 5s hold window.
    in_browser do
      InstantRecord::Client.apply_change(
        "type" => "Note", "id" => note.id, "operation" => "update", "version" => 2,
        "attributes" => { "id" => note.id, "title" => "remote-v2", "updated_at" => (Time.now.utc + 60).iso8601(6) }
      )
      assert InstantRecord.cancel_pending(mutation_id)
    end

    note.reload
    assert_equal "remote-v2", note.title, "cancel_pending must preserve the newer remote update"
    assert_equal 2, note.server_version
    assert_equal "synced", note.sync_state
    assert_equal 0, InstantRecord::OutboxMutation.count

    # Remote destroy during a held update must not be resurrected on cancel.
    in_browser { note.update!(title: "local-held-2", hold_for: 5) }
    mutation_id_2 = note.last_outbox_mutation_id
    in_browser do
      InstantRecord::Client.apply_change(
        "type" => "Note", "id" => note.id, "operation" => "destroy", "version" => 0, "attributes" => {}
      )
      assert InstantRecord.cancel_pending(mutation_id_2)
    end

    refute @model.exists?(note.id), "cancel_pending must not resurrect a remotely destroyed row"
    assert_equal 0, InstantRecord::OutboxMutation.count
  end

  def test_cancel_pending_does_not_leak_into_changed_records
    InstantRecord::Client.changed_records.clear
    note = in_browser { @model.create!(title: "ephemeral", hold_for: 5) }

    assert in_browser { InstantRecord.cancel_pending(note.last_outbox_mutation_id) }
    assert_empty InstantRecord::Client.changed_records
  end

  def test_explicit_destroy_hold_for_overrides_stale_instance_hold_for
    note = in_browser { @model.create!(title: "target") }
    InstantRecord::OutboxMutation.delete_all

    in_browser do
      note.hold_for = 10
      note.destroy!(hold_for: 0)
    end

    assert_nil InstantRecord::OutboxMutation.sole.release_at
  end

  def test_outbox_mutation_ids_are_strictly_monotonic_within_same_timestamp
    ids = Array.new(5) { InstantRecord::OutboxMutation.next_monotonic_id }
    assert_equal ids.sort, ids
    assert_equal 5, ids.uniq.size
  end
end
