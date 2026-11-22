require "test_helper"
require "active_job"
require "rails"
require "action_controller"
require "rack/mock"
require File.expand_path("../app/controllers/instant_record/mutations_controller", __dir__)

ActiveRecord::Migration.suppress_messages do
  ActiveRecord::Schema.define do
    create_table :mutator_accounts, id: :string, force: true do |t|
      t.string :owner
      t.integer :balance, null: false, default: 0
      t.integer :server_version, null: false, default: 0
      t.string :sync_state, null: false, default: "synced"
      t.timestamps
    end

    create_table :mutator_entries, id: :string, force: true do |t|
      t.string :from_id
      t.string :to_id
      t.integer :amount, null: false, default: 0
      t.string :note
      t.string :owner
      t.integer :server_version, null: false, default: 0
      t.string :sync_state, null: false, default: "synced"
      t.timestamps
    end
  end
end

class MutatorTestJob < ActiveJob::Base
  self.queue_adapter = :test
  def perform(*); end
end

class SyncActionsTest < Minitest::Test
  def setup
    ensure_mutator_tables!
    reset_instant_record_tables!
    ActiveRecord::Base.connection.execute("DELETE FROM mutator_accounts")
    ActiveRecord::Base.connection.execute("DELETE FROM mutator_entries")
    InstantRecord::SyncActions.reset_registry!
    MutatorTestJob.queue_adapter.enqueued_jobs.clear
    MutatorTestJob.queue_adapter.performed_jobs.clear
    @previous_scope = InstantRecord.config.scope_from

    @account = Class.new(ActiveRecord::Base) do
      self.table_name = "mutator_accounts"
      define_singleton_method(:name) { "Account" }
      include InstantRecord::Syncable
      validates :balance, numericality: { greater_than_or_equal_to: 0 }
    end

    @entry = Class.new(ActiveRecord::Base) do
      self.table_name = "mutator_entries"
      define_singleton_method(:name) { "TransferEntry" }
      include InstantRecord::Syncable
    end

    @item = syncable_model("Item") do
      validates :title, presence: true
    end

    account_cls = @account
    entry_cls = @entry

    @account.class_eval do
      sync_action :transfer
      define_singleton_method(:transfer) do |args|
        amount = args["amount"].to_i
        raise ArgumentError, "Amount must be positive" unless amount > 0

        from = account_cls.find(args["from_id"])
        to = account_cls.find(args["to_id"])
        raise InstantRecord::MutationRejected, "Insufficient funds" if from.balance < amount

        from.update!(balance: from.balance - amount)
        to.update!(balance: to.balance + amount)
        entry = entry_cls.create!(
          id: args["entry_id"],
          from_id: from.id,
          to_id: to.id,
          amount: amount,
          note: args["note"]
        )
        if args["draft_id"]
          entry_cls.find_by(id: args["draft_id"])&.destroy!
        end
        if !InstantRecord.browser? && args["notify"]
          MutatorTestJob.perform_later(entry.id, amount)
        end
        raise InstantRecord::MutationRejected, "Abort after job" if args["fail_after_job"]
        entry
      end

      sync_action :credit
      define_singleton_method(:credit) do |id:, amount:, note: "bonus"|
        acc = account_cls.find(id)
        acc.update!(balance: acc.balance + amount.to_i)
        entry_cls.create!(to_id: acc.id, amount: amount.to_i, note: note)
      end

      sync_action :seed_zero
      define_singleton_method(:seed_zero) do
        account_cls.create!(balance: 0)
      end
    end

    InstantRecord.sync(@account, @entry, @item)
  end

  def teardown
    InstantRecord.sync
    InstantRecord::SyncActions.reset_registry!
    InstantRecord.config.scope_from = @previous_scope
  end

  # --- DSL, Savepoint, and Deterministic UUIDs --------------------------------

  def test_client_sync_action_runs_in_savepoint_and_queues_one_mutator_intent
    from = on_server { @account.create!(id: "acc-a", balance: 100) }
    to = on_server { @account.create!(id: "acc-b", balance: 20) }
    draft = on_server { @entry.create!(id: "draft-1", amount: 5, note: "draft") }

    created = in_browser do
      @account.perform_sync_action(
        :transfer,
        from_id: from.id,
        to_id: to.id,
        amount: 35,
        note: "rent",
        draft_id: draft.id
      )
    end

    assert_equal 65, from.reload.balance
    assert_equal "pending", from.sync_state
    assert_equal 55, to.reload.balance
    assert_equal "pending", to.sync_state
    assert_equal 35, created.amount
    assert_equal "pending", created.sync_state
    refute @entry.exists?(draft.id)

    # Exactly ONE outbox intent — zero per-row create/update/destroy rows.
    outbox = InstantRecord::OutboxMutation.sole
    assert_equal "mutator", outbox.operation
    assert_equal "Account", outbox.record_type
    assert_equal "Account.transfer", outbox.record_id
    assert outbox.mutator?

    wire = outbox.as_mutation
    assert_equal outbox.id, wire[:mutation_id]
    assert_equal outbox.id, wire[:id]
    assert_equal "Account.transfer", wire[:mutator]
    assert_equal({ "from_id" => "acc-a", "to_id" => "acc-b", "amount" => 35, "note" => "rent", "draft_id" => "draft-1" }, wire[:args])
    refute wire.key?(:touched), "local rollback snapshots must not leak onto the wire"
    assert_equal 4, outbox.touched_records.size
  end

  def test_client_savepoint_rolls_back_all_writes_and_queues_nothing_on_failure
    from = on_server { @account.create!(id: "acc-a", balance: 100) }
    to = on_server { @account.create!(id: "acc-b", balance: 20) }

    err = assert_raises(InstantRecord::MutationRejected) do
      in_browser do
        @account.perform_sync_action(
          :transfer,
          from_id: from.id,
          to_id: to.id,
          amount: 40,
          fail_after_job: true
        )
      end
    end

    assert_equal "Abort after job", err.message
    assert_equal 100, from.reload.balance
    assert_equal "synced", from.sync_state
    assert_equal 20, to.reload.balance
    assert_equal 0, @entry.count
    assert_equal 0, InstantRecord::OutboxMutation.count
  end

  def test_deterministic_uuids_match_across_browser_and_server_replay
    on_server { @account.create!(id: "acc-a", balance: 100) }
    on_server { @account.create!(id: "acc-b", balance: 10) }

    client_entry = in_browser do
      @account.perform_sync_action(:transfer, from_id: "acc-a", to_id: "acc-b", amount: 25, mutation_id: "mut-det-1")
    end
    assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/, client_entry.id)

    # Reset DB to pre-mutation server state and replay the exact wire intent on server.
    wire = InstantRecord::OutboxMutation.sole.as_mutation
    ActiveRecord::Base.connection.execute("DELETE FROM mutator_accounts")
    ActiveRecord::Base.connection.execute("DELETE FROM mutator_entries")
    InstantRecord::Change.delete_all
    on_server { @account.create!(id: "acc-a", balance: 100) }
    on_server { @account.create!(id: "acc-b", balance: 10) }

    result = on_server { InstantRecord::MutationApplier.apply(wire) }
    assert_equal "applied", result[:status]
    server_entry = @entry.sole
    assert_equal client_entry.id, server_entry.id, "server replay must derive the identical UUID"
  end

  def test_keyword_args_zero_args_and_block_form_sync_actions
    acc = on_server { @account.create!(id: "acc-k", balance: 10) }

    entry = in_browser { @account.perform_sync_action(:credit, id: acc.id, amount: 15) }
    assert_equal 25, acc.reload.balance
    assert_equal "bonus", entry.note

    zero = in_browser { InstantRecord.mutate("Account.seed_zero") }
    assert_equal 0, zero.balance

    @item.sync_action(:retitle) do |args|
      rec = find(args["id"])
      rec.update!(title: args["title"])
      rec
    end
    item = on_server { @item.create!(id: "it-1", title: "old") }
    in_browser { @item.perform_sync_action(:retitle, id: "it-1", title: "new") }
    assert_equal "new", item.reload.title
  end

  def test_invalid_sync_action_name_raises_argument_error
    assert_raises(ArgumentError) { @item.sync_action("123bad") }
    assert_raises(ArgumentError) { @item.sync_action("has space") }
  end

  def test_nested_mutate_in_browser_keeps_single_outbox_intent
    acc_cls = @account
    @account.sync_action(:double_seed)
    @account.define_singleton_method(:double_seed) do |_args|
      a = InstantRecord.mutate("Account.seed_zero")
      b = acc_cls.perform_sync_action(:seed_zero)
      [a, b]
    end

    pair = in_browser { @account.perform_sync_action(:double_seed) }
    assert_equal 2, pair.size
    assert_equal 2, @account.count
    assert_equal 1, InstantRecord::OutboxMutation.count
    assert_equal "Account.double_seed", InstantRecord::OutboxMutation.sole.mutator_name
  end

  def test_direct_server_invocation_runs_in_one_transaction_and_logs_changes
    from = on_server { @account.create!(id: "acc-a", balance: 100) }
    to = on_server { @account.create!(id: "acc-b", balance: 10) }
    InstantRecord::Change.delete_all

    entry = on_server do
      @account.perform_sync_action(:transfer, from_id: from.id, to_id: to.id, amount: 30, note: "direct")
    end

    assert_equal 0, InstantRecord::OutboxMutation.count
    assert_equal 70, from.reload.balance
    assert_equal 2, from.server_version
    assert_equal 40, to.reload.balance
    assert_equal 2, to.server_version
    assert_equal 1, entry.server_version
    assert_equal %w[update update create], InstantRecord::Change.order(:id).pluck(:operation)
  end

  # --- Server MutationApplier: Transactionality, Idempotency & Security ------

  def test_server_replay_minimal_intent_bumps_versions_logs_changes_and_is_idempotent
    on_server { @account.create!(id: "acc-a", balance: 100) }
    on_server { @account.create!(id: "acc-b", balance: 20) }
    InstantRecord::Change.delete_all

    intent = {
      mutator: "Account.transfer",
      args: { from_id: "acc-a", to_id: "acc-b", amount: 30, note: "wire", notify: true },
      mutation_id: "mut-minimal-1"
    }

    first = on_server { InstantRecord::MutationApplier.apply(intent) }
    assert_equal "applied", first[:status]
    assert_equal "mut-minimal-1", first[:mutation_id]
    assert_equal 3, first[:records].size
    assert_equal 70, @account.find("acc-a").balance
    assert_equal 2, @account.find("acc-a").server_version
    assert_equal 50, @account.find("acc-b").balance
    assert_equal 2, @account.find("acc-b").server_version
    assert_equal 1, @entry.count
    assert_equal 3, InstantRecord::Change.count
    assert_equal 1, MutatorTestJob.queue_adapter.enqueued_jobs.size

    # Replay with identical mutation_id must return original result with zero side effects.
    replay = on_server { InstantRecord::MutationApplier.apply(intent) }
    assert_equal first, replay
    assert_equal 70, @account.find("acc-a").balance
    assert_equal 3, InstantRecord::Change.count
    assert_equal 1, MutatorTestJob.queue_adapter.enqueued_jobs.size
  end

  def test_unknown_or_undeclared_mutator_is_rejected_and_never_invoked
    called = false
    @account.define_singleton_method(:secret_admin_wipe) { |_args| called = true }

    res1 = on_server do
      InstantRecord::MutationApplier.apply(mutator: "Account.secret_admin_wipe", args: {}, mutation_id: "m-sec-1")
    end
    res2 = on_server do
      InstantRecord::MutationApplier.apply(mutator: "Kernel.system", args: {}, mutation_id: "m-sec-2")
    end

    assert_equal "rejected", res1[:status]
    assert_equal "unknown mutator", res1[:reason]
    assert_equal "rejected", res2[:status]
    assert_equal "unknown mutator", res2[:reason]
    refute called, "undeclared methods must never be dispatched"
  end

  # --- In-Transaction / Commit-Guarded ActiveJob Enqueueing ------------------

  def test_active_job_is_not_enqueued_when_server_mutator_rolls_back
    on_server { @account.create!(id: "acc-a", balance: 100) }
    on_server { @account.create!(id: "acc-b", balance: 20) }
    InstantRecord::Change.delete_all

    result = on_server do
      InstantRecord::MutationApplier.apply(
        mutator: "Account.transfer",
        args: { from_id: "acc-a", to_id: "acc-b", amount: 30, notify: true, fail_after_job: true },
        mutation_id: "mut-job-rollback"
      )
    end

    assert_equal "rejected", result[:status]
    assert_equal "Abort after job", result[:reason]
    assert_equal 100, @account.find("acc-a").balance
    assert_equal 20, @account.find("acc-b").balance
    assert_equal 0, @entry.count
    assert_equal 0, InstantRecord::Change.count
    assert_empty MutatorTestJob.queue_adapter.enqueued_jobs, "rolled-back mutator must enqueue zero jobs"
  end

  def test_active_job_waits_for_outer_transaction_and_drops_on_outer_rollback
    on_server { @account.create!(id: "acc-a", balance: 100) }
    on_server { @account.create!(id: "acc-b", balance: 20) }

    ActiveRecord::Base.transaction do
      on_server do
        InstantRecord::MutationApplier.apply(
          mutator: "Account.transfer",
          args: { from_id: "acc-a", to_id: "acc-b", amount: 10, notify: true },
          mutation_id: "mut-outer-rollback"
        )
      end
      assert_empty MutatorTestJob.queue_adapter.enqueued_jobs, "job must not enqueue before outer transaction commits"
      raise ActiveRecord::Rollback
    end

    assert_empty MutatorTestJob.queue_adapter.enqueued_jobs
    assert_equal 100, @account.find("acc-a").balance
  end

  # --- Unified Authorization (authorize_sync_action + SyncScope) -------------

  def test_authorize_sync_action_blocks_unauthorized_identity_and_rolls_back
    on_server { @account.create!(id: "acc-a", balance: 100) }
    on_server { @account.create!(id: "acc-b", balance: 20) }

    @account.authorize_sync_action(:transfer) { |identity, _args| identity&.id == "ada" }

    denied = on_server do
      InstantRecord::MutationApplier.apply(
        { mutator: "Account.transfer", args: { from_id: "acc-a", to_id: "acc-b", amount: 10, notify: true }, mutation_id: "auth-1" },
        Person.new("ben")
      )
    end
    assert_equal "rejected", denied[:status]
    assert_equal "not permitted", denied[:reason]
    assert_equal 100, @account.find("acc-a").balance
    assert_empty MutatorTestJob.queue_adapter.enqueued_jobs

    allowed = on_server do
      InstantRecord::MutationApplier.apply(
        { mutator: "Account.transfer", args: { from_id: "acc-a", to_id: "acc-b", amount: 10, notify: true }, mutation_id: "auth-2" },
        Person.new("ada")
      )
    end
    assert_equal "applied", allowed[:status]
    assert_equal 90, @account.find("acc-a").balance
    assert_equal 1, MutatorTestJob.queue_adapter.enqueued_jobs.size
  end

  def test_unified_sync_scope_and_writable_by_enforced_across_multi_row_mutator
    scoped_item = scoped_model("Item")
    scoped_item.sync_action(:swap_and_create)
    scoped_item.define_singleton_method(:swap_and_create) do |args|
      target = find(args["target_id"])
      target.update!(title: args["new_title"], state: args["new_state"] || target.state)
      create!(title: "audit", state: args["create_state"])
    end
    InstantRecord.sync(scoped_item)

    ada = Person.new("ada")
    ben = Person.new("ben")
    on_server { scoped_item.create!(id: "ada-1", title: "Ada row", state: "ada") }
    on_server { scoped_item.create!(id: "ben-1", title: "Ben row", state: "ben") }
    on_server { scoped_item.create!(id: "pub-1", title: "Public row", state: "public") }
    InstantRecord::Change.delete_all

    # Writing to own row + creating own audit succeeds.
    ok = on_server do
      InstantRecord::MutationApplier.apply(
        { mutator: "Item.swap_and_create", args: { target_id: "ada-1", new_title: "Ada v2", create_state: "ada" }, mutation_id: "sc-1" },
        ada
      )
    end
    assert_equal "applied", ok[:status]
    assert_equal "Ada v2", scoped_item.find("ada-1").title

    # Replaying as Ben must NOT leak Ada's records in `records`.
    ben_replay = on_server do
      InstantRecord::MutationApplier.apply(
        { mutator: "Item.swap_and_create", args: { target_id: "ada-1", new_title: "Ada v2", create_state: "ada" }, mutation_id: "sc-1" },
        ben
      )
    end
    assert_equal "applied", ben_replay[:status]
    assert_empty ben_replay[:records], "another identity replaying a mutator must not receive hidden records"

    # First write succeeds (ada-1), second write fails writable_by (creating for ben) -> ENTIRE tx rolls back!
    cross_create = on_server do
      InstantRecord::MutationApplier.apply(
        { mutator: "Item.swap_and_create", args: { target_id: "ada-1", new_title: "Should Rollback", create_state: "ben" }, mutation_id: "sc-2" },
        ada
      )
    end
    assert_equal "rejected", cross_create[:status]
    assert_equal "not permitted", cross_create[:reason]
    assert_equal "Ada v2", scoped_item.find("ada-1").title, "first write must roll back when second write violates writable_by"
    assert_equal ["ada-1"], cross_create[:records].map { |r| r["id"] }

    # Moving own row out of writer's reach fails post-update check and rolls back.
    move_away = on_server do
      InstantRecord::MutationApplier.apply(
        { mutator: "Item.swap_and_create", args: { target_id: "ada-1", new_title: "Stolen", new_state: "ben", create_state: "ada" }, mutation_id: "sc-3" },
        ada
      )
    end
    assert_equal "rejected", move_away[:status]
    assert_equal "ada", scoped_item.find("ada-1").state

    # Touching Ben's hidden row fails and returns ZERO records (does not reveal hidden row).
    hidden_attempt = on_server do
      InstantRecord::MutationApplier.apply(
        { mutator: "Item.swap_and_create", args: { target_id: "ben-1", new_title: "Hacked", create_state: "ada" }, mutation_id: "sc-4" },
        ada
      )
    end
    assert_equal "rejected", hidden_attempt[:status]
    assert_empty hidden_attempt[:records], "hidden rows must never be returned in rejection payloads"
    assert_equal "Ben row", scoped_item.find("ben-1").title

    # Touching visible-but-not-writable public row fails and DOES return the visible public row for rollback.
    pub_attempt = on_server do
      InstantRecord::MutationApplier.apply(
        { mutator: "Item.swap_and_create", args: { target_id: "pub-1", new_title: "Defaced", create_state: "ada" }, mutation_id: "sc-5" },
        ada
      )
    end
    assert_equal "rejected", pub_attempt[:status]
    assert_equal ["pub-1"], pub_attempt[:records].map { |r| r["id"] }
    assert_equal "Public row", pub_attempt[:records].first["attributes"]["title"]
  end

  def test_sync_scope_column_is_stamped_and_enforced_inside_mutator
    owned = syncable_model("OwnedItem") do
      sync_scope :owner
      sync_action :make_pair
      define_singleton_method(:make_pair) do |args|
        a = create!(title: args["a"], owner: args["owner_override"])
        b = create!(title: args["b"])
        [a, b]
      end
    end
    InstantRecord.sync(owned)

    # Without scope -> rejected
    anon = on_server do
      InstantRecord::MutationApplier.apply(
        { mutator: "OwnedItem.make_pair", args: { a: "one", b: "two" }, mutation_id: "own-1" },
        nil
      )
    end
    assert_equal "rejected", anon[:status]
    assert_equal "a scope is required", anon[:reason]
    assert_equal 0, owned.count

    # With scope -> stamped onto both created records
    ok = on_server do
      InstantRecord::MutationApplier.apply(
        { mutator: "OwnedItem.make_pair", args: { a: "one", b: "two" }, mutation_id: "own-2" },
        "ada"
      )
    end
    assert_equal "applied", ok[:status]
    assert_equal %w[ada ada], owned.order(:title).pluck(:owner)

    # Spoofing another scope -> rejected & rolled back
    spoof = on_server do
      InstantRecord::MutationApplier.apply(
        { mutator: "OwnedItem.make_pair", args: { a: "x", b: "y", owner_override: "ben" }, mutation_id: "own-3" },
        "ada"
      )
    end
    assert_equal "rejected", spoof[:status]
    assert_equal 2, owned.count
  end

  # --- End-to-End Client Reconciliation & Divergence Rollback ----------------

  def test_end_to_end_applied_mutator_reconciles_client_state
    from = on_server { @account.create!(id: "acc-a", balance: 100) }
    to = on_server { @account.create!(id: "acc-b", balance: 20) }
    draft = on_server { @entry.create!(id: "draft-1", amount: 1, note: "old") }

    created = in_browser do
      @account.perform_sync_action(
        :transfer,
        from_id: from.id,
        to_id: to.id,
        amount: 30,
        note: "e2e",
        draft_id: draft.id
      )
    end
    wire = InstantRecord::OutboxMutation.sole.as_mutation

    # Simulate authoritative server result with bumped server versions.
    result = {
      "mutation_id" => wire[:mutation_id],
      "status" => "applied",
      "records" => [
        { "type" => "Account", "id" => "acc-a", "operation" => "update", "version" => 2,
          "attributes" => InstantRecord.wire_attributes(from.reload.attributes.merge("balance" => 70)) },
        { "type" => "Account", "id" => "acc-b", "operation" => "update", "version" => 2,
          "attributes" => InstantRecord.wire_attributes(to.reload.attributes.merge("balance" => 50)) },
        { "type" => "TransferEntry", "id" => created.id, "operation" => "create", "version" => 1,
          "attributes" => InstantRecord.wire_attributes(created.reload.attributes) },
        { "type" => "TransferEntry", "id" => "draft-1", "operation" => "destroy", "version" => 0, "attributes" => {} }
      ]
    }

    in_browser { InstantRecord::Client.apply_results([result]) }

    assert_equal 0, InstantRecord.pending_count
    assert_equal "synced", from.reload.sync_state
    assert_equal 2, from.server_version
    assert_equal "synced", to.reload.sync_state
    assert_equal 2, to.server_version
    assert_equal "synced", created.reload.sync_state
    assert_equal 1, created.server_version
    refute @entry.exists?("draft-1")
  end

  def test_diverged_server_state_rejects_and_client_cleanly_rolls_back_all_touched_rows
    # Client starts with acc-a = 100 (v1), acc-b = 20 (v1), draft-1 (v1).
    from = on_server { @account.create!(id: "acc-a", balance: 100) }
    to = on_server { @account.create!(id: "acc-b", balance: 20) }
    draft = on_server { @entry.create!(id: "draft-1", amount: 5, note: "keep me") }
    server_stamp = from.updated_at

    # Client optimistically transfers 80 offline: acc-a -> 20, acc-b -> 100, creates entry, destroys draft-1.
    optimistic_entry = in_browser do
      @account.perform_sync_action(
        :transfer,
        from_id: from.id,
        to_id: to.id,
        amount: 80,
        note: "too big",
        draft_id: draft.id
      )
    end
    wire = InstantRecord::OutboxMutation.sole.as_mutation

    assert_equal 20, from.reload.balance
    assert_equal 100, to.reload.balance
    assert @entry.exists?(optimistic_entry.id)
    refute @entry.exists?("draft-1")

    # Server state diverged: acc-a already dropped to balance 40 (v5) before this intent arrived.
    # Simulate server replay on diverged state (with an older timestamp than local optimistic write!).
    server_result = {
      "mutation_id" => wire[:mutation_id],
      "status" => "rejected",
      "reason" => "Insufficient funds",
      "records" => [
        {
          "type" => "Account",
          "id" => "acc-a",
          "version" => 5,
          "attributes" => {
            "id" => "acc-a",
            "balance" => 40,
            "updated_at" => (server_stamp - 10).utc.iso8601(6),
            "created_at" => server_stamp.utc.iso8601(6)
          }
        }
      ]
    }

    in_browser { InstantRecord::Client.apply_results([server_result]) }

    # acc-a takes server's authoritative diverged state (balance 40, v5, synced).
    assert_equal 40, from.reload.balance
    assert_equal 5, from.server_version
    assert_equal "synced", from.sync_state

    # acc-b rolls back to its pre-mutation local snapshot (balance 20, v1, synced).
    assert_equal 20, to.reload.balance
    assert_equal 1, to.server_version
    assert_equal "synced", to.sync_state

    # Optimistically created TransferEntry is removed.
    refute @entry.exists?(optimistic_entry.id)

    # Optimistically destroyed draft-1 is restored from its local snapshot!
    restored_draft = @entry.find("draft-1")
    assert_equal "keep me", restored_draft.note
    assert_equal "synced", restored_draft.sync_state

    # Outbox is drained cleanly.
    assert_equal 0, InstantRecord.pending_count
  end

  def test_server_rejection_returns_read_record_even_when_mutator_raises_before_save
    on_server { @account.create!(id: "acc-a", balance: 15) }
    on_server { @account.create!(id: "acc-b", balance: 20) }

    # Transfer 50 fails immediately after reading acc-a & acc-b, before any save!
    result = on_server do
      InstantRecord::MutationApplier.apply(
        mutator: "Account.transfer",
        args: { from_id: "acc-a", to_id: "acc-b", amount: 50 },
        mutation_id: "diverge-read-1"
      )
    end

    assert_equal "rejected", result[:status]
    assert_equal "Insufficient funds", result[:reason]
    returned = result[:records].index_by { |r| r["id"] }
    assert_equal 15, returned.dig("acc-a", "attributes", "balance")
    assert_equal 20, returned.dig("acc-b", "attributes", "balance")
  end

  def test_identity_reset_drops_mutators_touching_reset_types_only
    on_server { @account.create!(id: "acc-a", balance: 100) }
    on_server { @account.create!(id: "acc-b", balance: 10) }
    on_server { @item.create!(id: "it-1", title: "open") }

    @item.sync_action(:touch_item) do |args|
      find(args["id"]).update!(title: args["title"])
    end

    in_browser do
      @account.perform_sync_action(:transfer, from_id: "acc-a", to_id: "acc-b", amount: 10)
      @item.perform_sync_action(:touch_item, id: "it-1", title: "still open")
    end
    assert_equal 2, InstantRecord::OutboxMutation.count

    # Resetting TransferEntry (touched by Account.transfer, not its owner_type!) must drop Account.transfer too.
    in_browser { InstantRecord::Client.reset("types" => ["TransferEntry"]) }

    assert_equal ["Item.touch_item"], InstantRecord::OutboxMutation.pluck(:record_id)
  end

  # --- MutationsController HTTP Integration ----------------------------------

  def test_mutations_controller_applies_mixed_batch_with_nested_args_and_checks_stale_identity
    on_server { @account.create!(id: "acc-a", balance: 100) }
    on_server { @account.create!(id: "acc-b", balance: 20) }

    @item.sync_action(:tag_with_nested) do |args|
      tags = args.dig("meta", "tags").join(",")
      create!(id: args["id"], title: "#{args['title']}:#{tags}")
    end

    InstantRecord.config.scope_from = ->(req) { Person.new(req.params["scope"]) }

    payload = {
      mutations: [
        {
          id: "row-1",
          record_type: "Item",
          record_id: "item-row-1",
          operation: "create",
          base_version: 0,
          changes: { title: "plain row" }
        },
        {
          mutation_id: "mut-http-1",
          mutator: "Account.transfer",
          args: { from_id: "acc-a", to_id: "acc-b", amount: 25, note: "via http" }
        },
        {
          mutation_id: "mut-http-nested",
          mutator: "Item.tag_with_nested",
          args: { id: "item-nested-1", title: "tagged", meta: { tags: %w[urgent sync] } }
        }
      ]
    }

    res = post_mutations(payload, scope: "ada")
    assert_equal 200, res[:status]
    results = res[:json]["results"]
    assert_equal %w[applied applied applied], results.map { |r| r["status"] }
    assert_equal 75, @account.find("acc-a").balance
    assert_equal 45, @account.find("acc-b").balance
    assert_equal "tagged:urgent,sync", @item.find("item-nested-1").title

    # Stale identity rejects scoped mutator without writing to AppliedMutation.
    @account.syncable_to { |who| who ? all : none }
    stale_res = post_mutations(
      {
        identity: InstantRecord::SyncScope.key(Person.new("ben")),
        mutations: [
          { mutation_id: "mut-stale-1", mutator: "Account.transfer", args: { from_id: "acc-a", to_id: "acc-b", amount: 5 } }
        ]
      },
      scope: "ada"
    )
    assert_equal "rejected", stale_res[:json]["results"].first["status"]
    assert_equal "identity changed", stale_res[:json]["results"].first["reason"]
    refute InstantRecord::AppliedMutation.exists?(mutation_id: "mut-stale-1")
  end

  def test_malformed_non_hash_args_is_rejected_cleanly_without_raising
    result = on_server do
      InstantRecord::MutationApplier.apply(
        mutator: "Account.transfer",
        args: "not-a-hash",
        mutation_id: "mut-bad-args"
      )
    end

    assert_equal "rejected", result[:status]
    assert_match(/must be a Hash/, result[:reason])
    assert_equal [], result[:records]
  end

  def test_rejected_rollback_preserves_original_updated_at_for_future_lww
    original_stamp = Time.utc(2026, 7, 1, 12, 0, 0, 123_456)
    from = on_server { @account.create!(id: "acc-a", balance: 100) }
    to = on_server { @account.create!(id: "acc-b", balance: 20) }
    to.update_columns(updated_at: original_stamp)

    in_browser do
      @account.perform_sync_action(:transfer, from_id: from.id, to_id: to.id, amount: 10)
    end
    wire = InstantRecord::OutboxMutation.sole.as_mutation

    in_browser do
      InstantRecord::Client.apply_results([
        { "mutation_id" => wire[:mutation_id], "status" => "rejected", "reason" => "nope", "records" => [] }
      ])
    end

    assert_equal original_stamp, to.reload.updated_at.utc,
      "restored snapshot must keep its pre-mutation updated_at so newer remote changes still win LWW"
  end

  private

  def ensure_mutator_tables!
    conn = ActiveRecord::Base.connection
    return if conn.table_exists?(:mutator_accounts) && conn.table_exists?(:mutator_entries)

    ActiveRecord::Migration.suppress_messages do
      ActiveRecord::Schema.define do
        create_table :mutator_accounts, id: :string, force: true do |t|
          t.string :owner
          t.integer :balance, null: false, default: 0
          t.integer :server_version, null: false, default: 0
          t.string :sync_state, null: false, default: "synced"
          t.timestamps
        end

        create_table :mutator_entries, id: :string, force: true do |t|
          t.string :from_id
          t.string :to_id
          t.integer :amount, null: false, default: 0
          t.string :note
          t.string :owner
          t.integer :server_version, null: false, default: 0
          t.string :sync_state, null: false, default: "synced"
          t.timestamps
        end
      end
    end
  end

  def post_mutations(body, scope: nil)
    query = scope ? "?scope=#{scope}" : ""
    env = Rack::MockRequest.env_for(
      "/instant_record/mutations#{query}",
      method: "POST",
      input: JSON.generate(body),
      "CONTENT_TYPE" => "application/json"
    )
    status, _headers, response_body = InstantRecord::MutationsController.action(:create).call(env)
    raw = +""
    response_body.each { |part| raw << part }
    response_body.close if response_body.respond_to?(:close)
    { status: status, json: JSON.parse(raw) }
  end
end
