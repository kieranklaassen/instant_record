require "test_helper"

class OutboxUpcasterTest < Minitest::Test
  def setup
    reset_instant_record_tables!
    InstantRecord.clear_outbox_upcasters!
  end

  def teardown
    InstantRecord.sync
    InstantRecord.clear_outbox_upcasters!
  end

  def test_n_minus_1_column_rename_upcaster_rescues_queued_offline_write
    model = syncable_model("Note") do
      upcast_outbox from: 1, to: 2 do |changes|
        changes["title"] = changes.delete("headline") if changes.key?("headline")
        changes
      end
    end
    InstantRecord.sync(model)

    result = on_server do
      InstantRecord::MutationApplier.apply(
        id: "n-minus-1-create",
        record_type: "Note",
        record_id: "note-1",
        operation: "create",
        schema_version: 1,
        changes: { "headline" => "Written offline on v1", "state" => "open" }
      )
    end

    assert_equal "applied", result[:status]
    assert_equal 1, result[:version]
    record = model.find("note-1")
    assert_equal "Written offline on v1", record.title
    assert_equal "open", record.state
  end

  def test_n_plus_1_downcast_upcaster_rescues_newer_client_hitting_older_server_during_rolling_deploy
    model = syncable_model("Note") do
      # Rolling deploy: v3 browser sends `word_count` to a v2 server that doesn't have the column yet.
      upcast_outbox from: 3, to: 2 do |changes|
        changes.except("word_count")
      end
    end
    InstantRecord.sync(model)

    result = on_server do
      InstantRecord::MutationApplier.apply(
        id: "n-plus-1-create",
        record_type: "Note",
        record_id: "note-2",
        operation: "create",
        schema_version: 3,
        changes: { "title" => "From canary browser", "word_count" => 3 }
      )
    end

    assert_equal "applied", result[:status]
    assert_equal "From canary browser", model.find("note-2").title
  end

  def test_chained_upcasters_run_in_order_and_skip_steps_already_applied_for_schema_version
    steps_run = []
    model = syncable_model("Note") do
      upcast_outbox from: 1, to: 2 do |changes|
        steps_run << :v1_to_v2
        changes["subject"] = changes.delete("legacy_name") if changes.key?("legacy_name")
      end

      upcast_outbox from: 2, to: 3 do |changes|
        steps_run << :v2_to_v3
        changes["title"] = changes.delete("subject") if changes.key?("subject")
      end
    end
    InstantRecord.sync(model)

    # Client at v1 runs both v1->v2 and v2->v3.
    res1 = on_server do
      InstantRecord::MutationApplier.apply(
        id: "chain-v1", record_type: "Note", record_id: "c-1",
        operation: "create", schema_version: 1,
        changes: { "legacy_name" => "From v1" }
      )
    end
    assert_equal "applied", res1[:status]
    assert_equal "From v1", model.find("c-1").title
    assert_equal %i[v1_to_v2 v2_to_v3], steps_run

    # Client at v2 skips v1->v2 and only runs v2->v3.
    steps_run.clear
    res2 = on_server do
      InstantRecord::MutationApplier.apply(
        id: "chain-v2", record_type: "Note", record_id: "c-2",
        operation: "create", schema_version: 2,
        changes: { "subject" => "From v2" }
      )
    end
    assert_equal "applied", res2[:status]
    assert_equal "From v2", model.find("c-2").title
    assert_equal %i[v2_to_v3], steps_run

    # Client already at v3 runs neither step.
    steps_run.clear
    res3 = on_server do
      InstantRecord::MutationApplier.apply(
        id: "chain-v3", record_type: "Note", record_id: "c-3",
        operation: "create", schema_version: 3,
        changes: { "title" => "From v3" }
      )
    end
    assert_equal "applied", res3[:status]
    assert_equal "From v3", model.find("c-3").title
    assert_empty steps_run
  end

  def test_legacy_client_without_schema_version_still_runs_versioned_upcasters
    model = syncable_model("Note") do
      upcast_outbox from: 1, to: 2 do |changes|
        changes["title"] = changes.delete("old_title") if changes.key?("old_title")
      end
    end
    InstantRecord.sync(model)

    result = on_server do
      InstantRecord::MutationApplier.apply(
        id: "legacy-no-version", record_type: "Note", record_id: "leg-1",
        operation: "create", changes: { "old_title" => "From unversioned client" }
      )
    end

    assert_equal "applied", result[:status]
    assert_equal "From unversioned client", model.find("leg-1").title
  end

  def test_operation_filter_and_two_arg_mutation_context
    seen_ops = []
    model = syncable_model("Note") do
      upcast_outbox operation: :create do |changes, mutation|
        seen_ops << [mutation[:operation], mutation[:record_id]]
        changes["state"] ||= "draft"
      end
    end
    InstantRecord.sync(model)

    on_server do
      InstantRecord::MutationApplier.apply(
        id: "op-1", record_type: "Note", record_id: "n-op",
        operation: "create", changes: { "title" => "First" }
      )
      InstantRecord::MutationApplier.apply(
        id: "op-2", record_type: "Note", record_id: "n-op",
        operation: "update", changes: { "title" => "Second" }
      )
    end

    assert_equal [["create", "n-op"]], seen_ops
    assert_equal "draft", model.find("n-op").state
    assert_equal "Second", model.find("n-op").title
  end

  def test_global_upcaster_can_rename_record_type_and_transform_payload
    model = syncable_model("Note")
    InstantRecord.sync(model)

    InstantRecord.upcast_outbox("LegacyMemo") do |changes, mutation|
      mutation[:record_type] = "Note"
      changes["title"] = changes.delete("memo_text") if changes.key?("memo_text")
      changes
    end

    result = on_server do
      InstantRecord::MutationApplier.apply(
        id: "renamed-model-1",
        record_type: "LegacyMemo",
        record_id: "m-1",
        operation: "create",
        changes: { "memo_text" => "Survived model rename" }
      )
    end

    assert_equal "applied", result[:status]
    assert_equal "Survived model rename", model.find("m-1").title
  end

  def test_upcaster_cannot_bypass_sync_scope_or_writable_by_authorization
    model = syncable_model("Note") do
      sync_scope :owner
      upcast_outbox do |changes|
        changes["title"] = changes.delete("old_title") if changes.key?("old_title")
        changes["owner"] = "victim"
        changes
      end
    end
    InstantRecord.sync(model)

    result = on_server do
      InstantRecord::MutationApplier.apply(
        { id: "scoped-upcast", record_type: "Note", record_id: "s-1",
          operation: "create", changes: { "old_title" => "Forged owner" } },
        "attacker"
      )
    end

    assert_equal "applied", result[:status]
    assert_equal "attacker", model.find("s-1").owner, "sync_scope must still stamp the real sender after upcasting"
  end

  def test_unhandled_unknown_column_still_rejects_cleanly_after_upcasters_run
    model = syncable_model("Note") do
      upcast_outbox do |changes|
        changes["title"] = changes.delete("old_title") if changes.key?("old_title")
      end
    end
    InstantRecord.sync(model)

    result = on_server do
      InstantRecord::MutationApplier.apply(
        id: "still-unknown", record_type: "Note", record_id: "u-1",
        operation: "create", changes: { "old_title" => "Mapped", "mystery_col" => 42 }
      )
    end

    assert_equal "rejected", result[:status]
    assert_match(/mystery_col/, result[:reason])
    assert_equal 0, model.count
  end

  def test_upcast_outbox_is_a_no_op_in_browser_runtime
    model = in_browser do
      syncable_model("BrowserNote") do
        upcast_outbox { |c| c }
      end
    end

    assert_empty model.instant_record_outbox_upcasters
  end

  def test_register_and_model_upcast_outbox_require_a_block
    assert_raises(ArgumentError) { InstantRecord::OutboxUpcaster.register("Note", from: 1, to: 2) }
    assert_raises(ArgumentError) { InstantRecord.upcast_outbox("Note") }
    assert_raises(ArgumentError) do
      syncable_model("Note") { upcast_outbox from: 1, to: 2 }
    end
  end

  def test_from_only_to_only_and_equal_version_bounds
    from_only_model = syncable_model("FromOnly") do
      upcast_outbox from: 2 do |changes|
        changes["tag"] = "from_2"
      end
    end
    to_only_model = syncable_model("ToOnly") do
      upcast_outbox to: 3 do |changes|
        changes["tag"] = "below_3"
      end
    end
    exact_model = syncable_model("Exact") do
      upcast_outbox from: 2, to: 2 do |changes|
        changes["tag"] = "exact_2"
      end
    end

    assert_equal({}, InstantRecord::OutboxUpcaster.apply_for_model(from_only_model, {}, { schema_version: 1 }))
    assert_equal({ "tag" => "from_2" }, InstantRecord::OutboxUpcaster.apply_for_model(from_only_model, {}, { schema_version: 2 }))
    assert_equal({ "tag" => "from_2" }, InstantRecord::OutboxUpcaster.apply_for_model(from_only_model, {}, { schema_version: " 2 " }))
    assert_equal({}, InstantRecord::OutboxUpcaster.apply_for_model(from_only_model, {}, { schema_version: 3 }))
    assert_equal({ "tag" => "from_2" }, InstantRecord::OutboxUpcaster.apply_for_model(from_only_model, {}, { schema_version: "" }))

    assert_equal({ "tag" => "below_3" }, InstantRecord::OutboxUpcaster.apply_for_model(to_only_model, {}, { schema_version: 1 }))
    assert_equal({ "tag" => "below_3" }, InstantRecord::OutboxUpcaster.apply_for_model(to_only_model, {}, { schema_version: 2 }))
    assert_equal({}, InstantRecord::OutboxUpcaster.apply_for_model(to_only_model, {}, { schema_version: 3 }))
    assert_equal({}, InstantRecord::OutboxUpcaster.apply_for_model(to_only_model, {}, { schema_version: 4 }))

    assert_equal({}, InstantRecord::OutboxUpcaster.apply_for_model(exact_model, {}, { schema_version: 1 }))
    assert_equal({ "tag" => "exact_2" }, InstantRecord::OutboxUpcaster.apply_for_model(exact_model, {}, { schema_version: 2 }))
    assert_equal({}, InstantRecord::OutboxUpcaster.apply_for_model(exact_model, {}, { schema_version: 3 }))
  end

  def test_transform_arities_and_non_hash_return_values
    zero_arg_hash = -> { { replaced: "yes" } }
    zero_arg_non_hash = -> { :ignored }
    one_arg_optional_lambda = ->(changes = {}) { changes.merge("opt_lambda" => true) }
    one_arg_optional_proc = proc { |changes = {}| changes["opt_proc"] = true; nil }
    splat_lambda = ->(*args) { args[0].merge("splat_count" => args.length) }
    one_plus_rest_lambda = ->(changes, *rest) { changes.merge("rest_op" => rest.first[:operation]) }
    two_plus_rest_lambda = ->(changes, mutation, *rest) { changes.merge("two_rest" => [mutation[:record_id], rest.length]) }

    InstantRecord::OutboxUpcaster.register("Note", &zero_arg_hash)
    _, out = InstantRecord::OutboxUpcaster.apply_global({ record_type: "Note" }, { original: "no" })
    assert_equal({ "replaced" => "yes" }, out)

    InstantRecord.clear_outbox_upcasters!
    InstantRecord::OutboxUpcaster.register("Note", &zero_arg_non_hash)
    InstantRecord::OutboxUpcaster.register("Note", &one_arg_optional_lambda)
    InstantRecord::OutboxUpcaster.register("Note", &one_arg_optional_proc)
    InstantRecord::OutboxUpcaster.register("Note", &splat_lambda)
    InstantRecord::OutboxUpcaster.register("Note", &one_plus_rest_lambda)
    InstantRecord::OutboxUpcaster.register("Note", &two_plus_rest_lambda)

    _, combined = InstantRecord::OutboxUpcaster.apply_global(
      { record_type: "Note", record_id: "r-9", operation: "update" },
      { title: "kept" }
    )

    assert_equal(
      {
        "title" => "kept",
        "opt_lambda" => true,
        "opt_proc" => true,
        "splat_count" => 2,
        "rest_op" => "update",
        "two_rest" => ["r-9", 0]
      },
      combined
    )
  end

  def test_global_upcaster_filters_by_record_type_and_normalizes_when_empty
    mutation, changes = InstantRecord::OutboxUpcaster.apply_global(
      { "record_type" => "Note", "operation" => "create" },
      { title: "Hello" }
    )
    assert_equal({ record_type: "Note", operation: "create" }, mutation)
    assert_equal({ "title" => "Hello" }, changes)

    InstantRecord.upcast_outbox("LegacyMemo") do |c|
      c["from_legacy"] = true
    end
    InstantRecord.upcast_outbox do |c|
      c["from_any"] = true
    end

    _, note_changes = InstantRecord::OutboxUpcaster.apply_global(
      { "record_type" => "Note", "operation" => "create" },
      { title: "Hello" }
    )
    assert_equal({ "title" => "Hello", "from_any" => true }, note_changes)

    _, memo_changes = InstantRecord::OutboxUpcaster.apply_global(
      { "record_type" => "LegacyMemo", "operation" => "create" },
      { title: "Old" }
    )
    assert_equal({ "title" => "Old", "from_legacy" => true, "from_any" => true }, memo_changes)
  end

  def test_apply_for_model_handles_models_without_upcasters
    plain_object = Object.new
    assert_equal({ "title" => "Plain" }, InstantRecord::OutboxUpcaster.apply_for_model(plain_object, { title: "Plain" }))

    model_without_rules = syncable_model("PlainNote")
    assert_equal({ "title" => "Empty" }, InstantRecord::OutboxUpcaster.apply_for_model(model_without_rules, { title: "Empty" }))
  end
end
