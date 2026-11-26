require "test_helper"

class ActionReplayTest < Minitest::Test
  def setup
    reset_instant_record_tables!
    ActiveRecord::Base.connection.create_table :replay_accounts, id: :string, force: true do |t|
      t.integer :balance, null: false, default: 0
      t.integer :server_version, null: false, default: 0
      t.string :sync_state, null: false, default: "synced"
      t.timestamps
    end
    ActiveRecord::Base.connection.create_table :replay_entries, id: :string, force: true do |t|
      t.integer :amount, null: false, default: 0
      t.string :note
      t.integer :server_version, null: false, default: 0
      t.string :sync_state, null: false, default: "synced"
      t.timestamps
    end
    InstantRecord::SyncActions.reset_registry!

    @account = replay_model("Account", "replay_accounts") do
      validates :balance, numericality: { greater_than_or_equal_to: 0 }
    end
    @entry = replay_model("TransferEntry", "replay_entries")
    InstantRecord.sync(@account, @entry)
  end

  def teardown
    InstantRecord.sync
    InstantRecord::SyncActions.reset_registry!
    ActiveRecord::Base.connection.drop_table :replay_accounts
    ActiveRecord::Base.connection.drop_table :replay_entries
  end

  def test_each_rejection_answers_with_its_reason_and_the_rows_it_touched
    on_server { @account.create!(id: "acc-a", balance: 15) }
    on_server { @entry.create!(id: "taken", amount: 1, note: "first") }
    account = @account
    entry = @entry
    @account.sync_action(:overdraw) { |_args| account.find("acc-a").update!(balance: -1) }
    @account.sync_action(:reopen) { |_args| account.create!(id: "acc-a", balance: -1) }
    @account.sync_action(:lose) { |_args| account.find("acc-a") && account.find("gone") }
    @account.sync_action(:miss) { |_args| account.where(balance: 99).find("acc-a") }
    @account.sync_action(:collide) do |_args|
      account.find("acc-a").update!(balance: 1)
      InstantRecord::AppliedMutation.create!(mutation_id: "reject-collide", result_payload: {})
    end
    @account.sync_action(:retake) { |_args| account.find("acc-a") && entry.create!(id: "taken") }
    @account.sync_action(:misname) { |_args| account.find("acc-a").update!(nope: 1) }
    @account.sync_action(:misuse) { |_args| account.find("acc-a") && raise(ArgumentError, "Bad amount") }
    @account.sync_action(:refuse) { |_args| account.find("acc-a") && raise(InstantRecord::MutationApplier::NotPermitted) }
    @account.sync_action(:explain) { |_args| account.find("acc-a") && raise(InstantRecord::MutationApplier::NotPermitted, "Ask Ada") }
    @account.sync_action(:guarded) { |_args| account.find("acc-a") }
    @account.authorize_sync_action(:guarded) { |_identity, _args| false }
    lost = assert_raises(ActiveRecord::RecordNotFound) { @account.find("gone") }.message
    missed = assert_raises(ActiveRecord::RecordNotFound) { @account.where(balance: 99).find("acc-a") }.message

    {
      "overdraw" => ["Balance must be greater than or equal to 0", %w[acc-a]],
      "reopen" => ["Balance must be greater than or equal to 0", %w[acc-a]],
      "lose" => [lost, %w[acc-a]],
      "miss" => [missed, %w[acc-a]],
      "collide" => ["id already exists", %w[acc-a]],
      "retake" => ["id already exists", %w[acc-a taken]],
      "misname" => ["unknown attribute 'nope' for #{@account}.", %w[acc-a]],
      "misuse" => ["Bad amount", %w[acc-a]],
      "refuse" => ["not permitted", %w[acc-a]],
      "explain" => ["Ask Ada", %w[acc-a]],
      "guarded" => ["not permitted", []],
      "undeclared" => ["unknown mutator", []]
    }.each do |action, (reason, ids)|
      intent = { mutator: "Account.#{action}", args: {}, mutation_id: "reject-#{action}" }
      result = on_server { InstantRecord::MutationApplier.apply(intent) }

      assert_equal ["rejected", reason, "reject-#{action}"], result.values_at(:status, :reason, :mutation_id), action
      assert_equal ids, result[:records].map { |record| record["id"] }, action
      assert_equal result, on_server { InstantRecord::MutationApplier.apply(intent) }, "#{action} again"
    end
    assert_equal 15, @account.find("acc-a").balance
    assert_equal "first", @entry.find("taken").note
  end

  def test_a_concurrent_duplicate_rolls_back_and_answers_with_what_its_sender_may_see
    item = scoped_model("Item")
    item.sync_action(:add) { |args| item.create!(id: args["id"], title: "new", state: args["state"]) }
    InstantRecord.sync(item)
    intent = ->(who) { { mutator: "Item.add", args: { id: "#{who}-1", state: who }, mutation_id: "dup-1" } }

    first = on_server { InstantRecord::MutationApplier.apply(intent.("ada"), Person.new("ada")) }
    assert_equal ["ada-1"], first[:records].map { |record| record["id"] }

    second = missing_the_first_ledger_lookup do
      on_server { InstantRecord::MutationApplier.apply(intent.("ben"), Person.new("ben")) }
    end

    assert_equal "applied", second[:status]
    assert_empty second[:records]
    assert_equal ["ada-1"], item.pluck(:id)
  end

  def test_an_action_on_a_model_that_is_not_synced_is_unknown_and_never_runs
    called = false
    unsynced = syncable_model("Unsynced")
    unsynced.sync_action(:touch_it) { |_args| called = true }

    result = on_server do
      InstantRecord::MutationApplier.apply(mutator: "Unsynced.touch_it", args: {}, mutation_id: "unsynced-1")
    end

    assert_equal ["rejected", "unknown mutator", []], result.values_at(:status, :reason, :records)
    refute called
  end

  def test_any_declared_action_runs_when_no_model_is_listed_to_sync
    called = false
    syncable_model("Unlisted").sync_action(:touch_it) { |_args| called = true }
    InstantRecord.sync

    result = on_server do
      InstantRecord::MutationApplier.apply(mutator: "Unlisted.touch_it", args: {}, mutation_id: "unlisted-1")
    end

    assert_equal "applied", result[:status]
    assert called
  end

  def test_an_action_on_a_class_without_records_runs_beside_synced_models
    called = false
    Class.new do
      define_singleton_method(:name) { "Checkout" }
      include InstantRecord::SyncActions
      sync_action(:finish) { |_args| called = true }
    end

    result = on_server do
      InstantRecord::MutationApplier.apply(mutator: "Checkout.finish", args: {}, mutation_id: "plain-class-1")
    end

    assert_equal "applied", result[:status]
    assert called
  end

  def test_a_rejection_leaves_out_the_rows_of_a_model_that_is_not_listed
    unlisted = syncable_model("Unlisted")
    on_server { unlisted.create!(id: "u-1", title: "new") }
    @account.sync_action(:abort) do |_args|
      unlisted.find("u-1")
      raise InstantRecord::MutationRejected, "No"
    end

    result = on_server do
      InstantRecord::MutationApplier.apply(mutator: "Account.abort", args: {}, mutation_id: "unlisted-2")
    end

    assert_equal ["rejected", "No", []], result.values_at(:status, :reason, :records)
  end

  def test_an_error_the_replay_does_not_answer_is_raised_and_leaves_nothing_behind
    on_server { @account.create!(id: "acc-a", balance: 15) }
    account = @account
    @account.sync_action(:crash) do |_args|
      account.find("acc-a").update!(balance: 1)
      raise "boom"
    end

    on_server do
      error = assert_raises(RuntimeError) do
        InstantRecord::MutationApplier.apply(mutator: "Account.crash", args: {}, mutation_id: "crash-1")
      end
      assert_equal "boom", error.message
      assert_nil InstantRecord::SyncActions.server_frame
    end
    assert_equal 15, @account.find("acc-a").balance
    refute InstantRecord::AppliedMutation.exists?(mutation_id: "crash-1")
  end

  def test_an_authorizer_of_three_arguments_gets_the_action_too
    seen = []
    on_server { @account.create!(id: "acc-a", balance: 15) }
    account = @account
    @account.sync_action(:peek) { |args| account.find(args["id"]) }
    @account.authorize_sync_action do |action, identity, args|
      seen << [action.to_s, identity.id, args["id"]]
      identity.id == "ada"
    end

    statuses = %w[ada ben].map do |who|
      on_server do
        InstantRecord::MutationApplier.apply(
          { mutator: "Account.peek", args: { id: "acc-a" }, mutation_id: "peek-#{who}" }, Person.new(who)
        )[:status]
      end
    end

    assert_equal %w[applied rejected], statuses
    assert_equal [%w[peek ada acc-a], %w[peek ben acc-a]], seen
  end

  def test_an_authorizer_with_a_splat_gets_the_action_too
    seen = nil
    @account.sync_action(:peek) { |_args| nil }
    @account.authorize_sync_action { |action, identity, *rest| seen = [action.to_s, identity.id, rest] }

    on_server do
      InstantRecord::MutationApplier.apply(
        { mutator: "Account.peek", args: { id: "acc-a" }, mutation_id: "splat-1" }, Person.new("ada")
      )
    end

    assert_equal ["peek", "ada", [{ "id" => "acc-a" }]], seen
  end

  def test_a_stored_answer_keeps_each_operation_and_shows_a_destroy_to_no_other_sender
    item = scoped_model("Item")
    item.sync_action(:rename) { |args| item.find(args["id"]).update!(title: "renamed") }
    item.sync_action(:drop) { |args| item.find(args["id"]).destroy! }
    InstantRecord.sync(item)
    on_server { item.create!(id: "ada-1", title: "new", state: "ada") }
    apply = ->(action, who) do
      on_server do
        InstantRecord::MutationApplier.apply(
          { mutator: "Item.#{action}", args: { id: "ada-1" }, mutation_id: "stored-#{action}" }, Person.new(who)
        )
      end
    end

    apply.(:rename, "ada")
    assert_equal [%w[ada-1 update]], apply.(:rename, "ada")[:records].map { |record| record.values_at("id", "operation") }

    assert_equal ["applied", 1], apply.(:drop, "ada").then { |result| [result[:status], result[:records].size] }
    assert_equal ["applied", []], apply.(:drop, "ben").values_at(:status, :records)
    on_server { item.create!(id: "ada-1", title: "new", state: "ben") }
    assert_equal ["applied", []], apply.(:drop, "ben").values_at(:status, :records)
  end

  def test_a_rejection_inside_an_open_transaction_undoes_only_the_action
    on_server { @account.create!(id: "acc-a", balance: 15) }
    account = @account
    @account.sync_action(:abort) do |_args|
      account.find("acc-a").update!(balance: 1)
      raise InstantRecord::MutationRejected, "No"
    end

    result = ActiveRecord::Base.transaction do
      on_server { InstantRecord::MutationApplier.apply(mutator: "Account.abort", args: {}, mutation_id: "outer-1") }
    end

    assert_equal %w[rejected No], result.values_at(:status, :reason)
    assert_equal 15, @account.find("acc-a").balance
  end

  def test_a_rejection_recorded_first_stands
    @account.sync_action(:abort) { |_args| raise InstantRecord::MutationRejected, "No" }
    apply = ->(mutator) do
      on_server { InstantRecord::MutationApplier.apply(mutator: mutator, args: {}, mutation_id: "race-1") }
    end

    apply.("Account.undeclared")
    second = missing_the_first_ledger_lookup { apply.("Account.abort") }

    assert_equal ["rejected", "unknown mutator"], second.values_at(:status, :reason)
    assert_equal 1, InstantRecord::AppliedMutation.where(mutation_id: "race-1").count
  end

  def test_an_invalid_record_of_a_plain_model_is_answered_with_its_errors_alone
    on_server { @account.create!(id: "acc-a", balance: 15) }
    plain = Class.new(ActiveRecord::Base) do
      self.table_name = "items"
      define_singleton_method(:name) { "Account" }
      validates :title, presence: true
    end
    @account.sync_action(:log) { |_args| plain.create!(id: "acc-a") }

    result = on_server { InstantRecord::MutationApplier.apply(mutator: "Account.log", args: {}, mutation_id: "plain-1") }

    assert_equal ["rejected", "Title can't be blank", []], result.values_at(:status, :reason, :records)
  end

  def test_a_replayed_action_runs_as_a_client_mutation
    applying = nil
    @account.sync_action(:look) { |_args| applying = InstantRecord.applying_client_mutation? }

    on_server { InstantRecord::MutationApplier.apply(mutator: "Account.look", args: {}, mutation_id: "look-1") }

    assert_equal [true, false], [applying, InstantRecord.applying_client_mutation?]
  end

  def test_a_partitioned_model_is_held_to_its_partition_in_a_replayed_action
    tenant = syncable_model("TenantItem") { sync_partition :owner }
    tenant.sync_action(:add) { |args| tenant.create!(id: args["id"], title: "new") }
    tenant.sync_action(:rename) { |args| tenant.find(args["id"]).update!(title: "renamed") }
    tenant.sync_action(:refuse) do |args|
      tenant.find(args["id"])
      raise InstantRecord::MutationRejected, "No"
    end
    InstantRecord.sync(tenant)
    apply = ->(action, mutation_id, partition) do
      on_server do
        InstantRecord::MutationApplier.apply(
          { mutator: "TenantItem.#{action}", args: { id: "t-1" }, mutation_id: mutation_id }, nil, partition
        )
      end
    end
    ids = ->(result) { result[:records].map { |record| record["id"] } }

    added = apply.(:add, "part-1", "acme")
    assert_equal ["applied", ["t-1"], "acme"], [added[:status], ids.(added), tenant.find("t-1").owner]
    assert_equal ["t-1"], ids.(apply.(:add, "part-1", "acme"))
    assert_empty ids.(apply.(:add, "part-1", "beta"))

    assert_equal "a partition is required", apply.(:rename, "part-2", nil)[:reason]
    foreign = apply.(:rename, "part-3", "beta")
    assert_equal ["rejected", "record not in active partition", []], foreign.values_at(:status, :reason, :records)
    assert_equal "new", tenant.find("t-1").title

    assert_equal ["t-1"], ids.(apply.(:refuse, "part-4", "acme"))
    assert_empty ids.(apply.(:refuse, "part-5", "beta"))
  end

  private

  def replay_model(name, table, &body)
    Class.new(ActiveRecord::Base) do
      self.table_name = table
      define_singleton_method(:name) { name }
      include InstantRecord::Syncable
      class_eval(&body) if body
    end
  end

  # The ledger as a sender sees it whose duplicate is recorded just after.
  def missing_the_first_ledger_lookup
    ledger = InstantRecord::AppliedMutation
    looked = false
    ledger.define_singleton_method(:find_by) do |*args, **options|
      next super(*args, **options) if looked

      looked = true
      nil
    end
    yield
  ensure
    ledger.singleton_class.send(:remove_method, :find_by)
  end
end
