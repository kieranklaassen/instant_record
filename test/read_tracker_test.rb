require "test_helper"

class ReadTrackerTest < Minitest::Test
  def setup
    @model = syncable_model("Memo") do
      sync_window limit: 20, partition_by: :owner
    end
    InstantRecord.sync(@model)
    reset_instant_record_tables!
  end

  def teardown
    InstantRecord.sync
  end

  def test_tracks_active_record_select_tables_models_and_partition_equality
    @model.create!(id: "m-1", title: "hi", owner: "maya")

    reads = InstantRecord::ReadTracker.track do
      @model.where(owner: "maya").to_a
    end

    assert_equal ["items"], reads["tables"]
    assert_equal ["Memo"], reads["models"]
    assert_equal({ "Memo" => { "owner" => ["maya"] } }, reads["partitions"])
  end

  def test_tracks_in_predicate_and_intersects_across_multiple_queries_on_same_table
    reads = InstantRecord::ReadTracker.track do
      InstantRecord::ReadTracker.record_sql(
        'SELECT * FROM "items" WHERE "items"."owner" = ? AND "items"."id" = ?',
        ["maya", "m-1"]
      )
      InstantRecord::ReadTracker.record_sql(
        'SELECT * FROM "items" WHERE "items"."owner" IN (?, ?)',
        ["maya", "theo"]
      )
    end

    # `id` was only constrained in the first query, so soundness drops it;
    # `owner` was constrained in both, so values union cleanly.
    assert_equal({ "Memo" => { "owner" => %w[maya theo] } }, reads["partitions"])
  end

  def test_unconstrained_query_or_top_level_or_widens_to_whole_table
    reads = InstantRecord::ReadTracker.track do
      InstantRecord::ReadTracker.record_sql('SELECT * FROM "items" WHERE "owner" = \'maya\'')
      InstantRecord::ReadTracker.record_sql('SELECT * FROM "items" WHERE "owner" = \'theo\' OR "title" = \'urgent\'')
    end

    assert_equal ["items"], reads["tables"]
    assert_equal ["Memo"], reads["models"]
    assert_equal({}, reads["partitions"])
  end

  def test_parenthesized_or_and_subquery_do_not_break_outer_partition_tracking
    reads = InstantRecord::ReadTracker.track do
      InstantRecord::ReadTracker.record_sql(
        <<~SQL
          SELECT * FROM "items"
          WHERE "items"."owner" = 'maya'
            AND (LOWER("items"."title") LIKE '%inv%' OR LOWER("items"."state") LIKE '%inv%')
            AND NOT EXISTS (SELECT 1 FROM items archived WHERE archived.id = items.id)
        SQL
      )
    end

    assert_equal({ "Memo" => { "owner" => ["maya"] } }, reads["partitions"])
  end

  def test_compound_query_narrows_nothing
    [
      "UNION", "UNION ALL", "INTERSECT", "EXCEPT", "union\nall", "Except"
    ].each do |operator|
      [
        "SELECT * FROM items WHERE owner = 'maya' #{operator} SELECT * FROM items",
        "SELECT * FROM items #{operator} SELECT * FROM items WHERE owner = 'maya'",
        "SELECT * FROM items WHERE owner = 'maya' #{operator} SELECT * FROM items WHERE owner = 'theo'",
        "SELECT * FROM items WHERE owner IN ('maya', 'th''eo') #{operator} VALUES (1) ORDER BY 1 LIMIT 5"
      ].each { |sql| assert_equal({}, reads_of(sql)["partitions"], sql) }
    end

    reads = reads_of("SELECT * FROM items WHERE owner = 'maya' UNION SELECT * FROM items")
    assert_equal ["items"], reads["tables"]
    other_owner = { "type" => "Memo", "id" => "1", "op" => "create", "attrs" => { "owner" => "theo" } }
    assert InstantRecord::ReadTracker.affects?([other_owner], reads)
  end

  def test_compound_keywords_that_are_not_operators_keep_the_narrowing
    [
      "SELECT * FROM items WHERE owner = 'maya' AND title = 'a UNION b'",
      "SELECT * FROM items WHERE owner = 'maya' AND title = 'it''s EXCEPT this'",
      "SELECT ' INTERSECT ' FROM items WHERE owner = 'maya'",
      "SELECT * FROM items WHERE items.owner = 'maya' AND id IN (SELECT item_id FROM labels UNION SELECT item_id FROM labels)",
      "SELECT * FROM items WHERE (items.owner = 'maya') AND NOT EXISTS (SELECT 1 FROM labels EXCEPT SELECT 2)",
      "SELECT union_id, reunion FROM items WHERE owner = 'maya' ORDER BY items.except_at, intersects",
      "SELECT \"union_id\" FROM items WHERE owner = 'maya' AND \"items\".\"is_except\" = 1"
    ].each { |sql| assert_equal({ "owner" => ["maya"] }, reads_of(sql)["partitions"]["Memo"], sql) }
  end

  def reads_of(sql)
    InstantRecord::ReadTracker.track { InstantRecord::ReadTracker.record_sql(sql) }
  end
  private :reads_of

  def test_ignores_internal_tables_and_non_select_queries
    reads = InstantRecord::ReadTracker.track do
      InstantRecord::ReadTracker.record_sql("PRAGMA table_info(items)")
      InstantRecord::ReadTracker.record_sql("INSERT INTO items (id) VALUES ('1')")
      InstantRecord::ReadTracker.record_sql("SELECT * FROM instant_record_outbox")
      InstantRecord::ReadTracker.record_sql("SELECT * FROM sqlite_master")
    end

    assert_equal({ "tables" => [], "models" => [], "partitions" => {} }, reads)
  end

  def test_affects_checks_tables_partitions_and_partition_moves
    reads = {
      "tables" => ["items"],
      "models" => ["Memo"],
      "partitions" => { "Memo" => { "owner" => ["maya"] } }
    }

    # Unaffected model -> skip
    refute InstantRecord::ReadTracker.affects?(
      [{ "type" => "OtherModel", "id" => "1", "op" => "create", "changed_columns" => ["title"], "attrs" => {} }],
      reads
    )

    # Different partition on create (partition column is in changed_columns for creates) -> skip
    refute InstantRecord::ReadTracker.affects?(
      [{ "type" => "Memo", "id" => "2", "op" => "create", "changed_columns" => %w[id owner title], "attrs" => { "id" => "2", "owner" => "jo", "title" => "x" } }],
      reads
    )

    # Different partition, partition column unchanged -> skip
    refute InstantRecord::ReadTracker.affects?(
      [{ "type" => "Memo", "id" => "1", "op" => "update", "changed_columns" => ["title"], "attrs" => { "owner" => "jo", "title" => "x" } }],
      reads
    )

    # Matching partition -> affects
    assert InstantRecord::ReadTracker.affects?(
      [{ "type" => "Memo", "id" => "1", "op" => "update", "changed_columns" => ["title"], "attrs" => { "owner" => "maya", "title" => "x" } }],
      reads
    )

    # Row moved out of partition (partition column itself in changed_columns) -> affects soundly
    assert InstantRecord::ReadTracker.affects?(
      [{ "type" => "Memo", "id" => "1", "op" => "update", "changed_columns" => ["owner"], "attrs" => { "owner" => "jo" } }],
      reads
    )

    # Wildcard nil -> affects
    assert InstantRecord::ReadTracker.affects?(nil, reads)
  end
end
