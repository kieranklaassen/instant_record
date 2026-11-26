require "test_helper"

class SyncPartitionTest < Minitest::Test
  class HeaderCapturingTransport
    attr_reader :calls
    attr_accessor :bootstrap_response, :mutations_response, :events_response, :records_response

    def initialize
      @calls = []
      @bootstrap_response = { "cursor" => 1, "records" => [] }
      @mutations_response = { "results" => [] }
      @events_response = ""
      @records_response = { "records" => [], "has_more" => false }
    end

    def get_json(path, headers: nil)
      @calls << [:get, path, headers]
      path.start_with?("/bootstrap") ? @bootstrap_response : @records_response
    end

    def post_json(path, payload, headers: nil)
      @calls << [:post, path, payload, headers]
      @mutations_response
    end

    def each_event(path, headers: nil, &block)
      @calls << [:events, path, headers]
      InstantRecord::Client::Transport::SseParser.new(&block).feed(@events_response)
    end
  end

  def setup
    reset_instant_record_tables!
    @saved_config = InstantRecord.instance_variable_get(:@config)
    InstantRecord.instance_variable_set(:@config, InstantRecord::Configuration.new)
    @partitioned = syncable_model("TenantItem") do
      sync_partition :owner
      sync_operations :create
    end
    @global = syncable_model("GlobalItem")
    InstantRecord.sync(@partitioned, @global)
  end

  def teardown
    InstantRecord.sync
    InstantRecord::Client.transport = nil
    InstantRecord.instance_variable_set(:@config, @saved_config)
  end

  def test_sync_partition_extracts_plain_qualified_and_hash_specifiers
    part = @partitioned.instant_record_sync_partition

    assert_equal "acme", part.extract("acme")
    assert_equal "acme", part.extract("owner:acme")
    assert_equal "acme", part.extract("owner=acme")
    assert_equal "acme", part.extract({ "owner" => "acme" })
    assert_equal "acme", part.extract({ owner: "acme" })
    assert_nil part.extract("other:acme")
    assert_nil part.extract("other=acme")
    assert_nil part.extract({ other: "acme" })
    assert_nil part.extract("")
    assert_nil part.extract(nil)
    assert_equal "owner:acme", part.change_key("acme")
  end

  # A compiled model's `[]` compares Symbols.
  def test_a_partition_reads_its_column_by_symbol
    record = Object.new
    def record.[](name) = { owner: "acme" }[name]

    assert_equal "owner:acme", @partitioned.instant_record_sync_partition.change_partition_for(record)
  end

  def test_models_for_isolates_partitioned_and_unpartitioned_sessions
    assert_equal [@global], InstantRecord::SyncScope.models_for(nil)
    assert_equal [@partitioned], InstantRecord::SyncScope.models_for("acme")
    assert_equal [@partitioned], InstantRecord::SyncScope.models_for("owner:acme")
    assert_empty InstantRecord::SyncScope.models_for("other:acme")
  end

  def test_server_writes_tag_changes_with_partition_and_poll_isolates_them
    on_server do
      @global.create!(id: "g-1", title: "global")
      @partitioned.create!(id: "a-1", title: "acme", owner: "acme")
      @partitioned.create!(id: "b-1", title: "beta", owner: "beta")
    end

    assert_equal %w[g-1], InstantRecord::Change.poll(0).map(&:record_id)
    assert_equal %w[a-1], InstantRecord::Change.poll(0, partition: "owner:acme").map(&:record_id)
    assert_equal %w[b-1], InstantRecord::Change.poll(0, partition: ["owner:beta"]).map(&:record_id)
    assert_empty InstantRecord::Change.poll(0, partition: [])
  end

  def test_mutation_applier_enforces_partition_and_allowed_operations
    no_part = InstantRecord::MutationApplier.apply(
      { id: "m1", record_type: "TenantItem", record_id: "t-1", operation: "create", changes: { "title" => "hi", "owner" => "acme" } },
      nil, nil
    )
    assert_equal "rejected", no_part[:status]
    assert_equal "a partition is required", no_part[:reason]

    wrong_part = InstantRecord::MutationApplier.apply(
      { id: "m2", record_type: "TenantItem", record_id: "t-1", operation: "create", changes: { "title" => "hi", "owner" => "beta" } },
      nil, "owner:acme"
    )
    assert_equal "rejected", wrong_part[:status]
    assert_equal "record not in active partition", wrong_part[:reason]

    ok = InstantRecord::MutationApplier.apply(
      { id: "m3", record_type: "TenantItem", record_id: "t-1", operation: "create", changes: { "title" => "hi" } },
      nil, "owner:acme"
    )
    assert_equal "applied", ok[:status]
    assert_equal "acme", @partitioned.find("t-1").owner
    assert_equal "owner:acme", InstantRecord::Change.last.partition

    # Replaying the same mutation_id inside the same partition is idempotent,
    # while replaying it without a partition or from another partition is rejected.
    replay_ok = InstantRecord::MutationApplier.apply(
      { id: "m3", record_type: "TenantItem", record_id: "t-1", operation: "create", changes: { "title" => "hi" } },
      nil, "owner:acme"
    )
    assert_equal "applied", replay_ok[:status]

    replay_unpartitioned = InstantRecord::MutationApplier.apply(
      { id: "m3", record_type: "TenantItem", record_id: "t-1", operation: "create", changes: { "title" => "hi" } },
      nil, nil
    )
    assert_equal "rejected", replay_unpartitioned[:status]

    replay_other_partition = InstantRecord::MutationApplier.apply(
      { id: "m3", record_type: "TenantItem", record_id: "t-1", operation: "create", changes: { "title" => "hi" } },
      nil, "owner:beta"
    )
    assert_equal "rejected", replay_other_partition[:status]

    # sync_operations :create rejects updates and destroys
    upd = InstantRecord::MutationApplier.apply(
      { id: "m4", record_type: "TenantItem", record_id: "t-1", operation: "update", changes: { "title" => "changed" } },
      nil, "owner:acme"
    )
    assert_equal "rejected", upd[:status]
    assert_equal "not permitted", upd[:reason]
  end

  def test_authorize_partition_allows_or_forbids_access
    model = syncable_model("Guarded") do
      sync_partition :owner
      authorize_partition { |part, who| who == part }
    end

    assert InstantRecord::SyncScope.authorize_partition!(model, "acme", "acme")
    assert_raises(InstantRecord::Forbidden) do
      InstantRecord::SyncScope.authorize_partition!(model, "acme", "stranger")
    end
  end

  def test_sync_shape_bootstrap_keyset_paging_search_lookup_and_fill_descriptor
    shaped = syncable_model("ShapedMail") do
      sync_partition :owner
      sync_shape(
        limit: 2,
        max_limit: 5,
        roots: -> { where(state: "open") },
        include: ->(roots) { where(state: "reply", title: roots.map(&:id)) },
        search: ->(term) { where("LOWER(title) LIKE ?", "%#{term.downcase}%") },
        lookup: ->(id) { where(id: id, state: "open") },
        background_fill: true,
        fill_page_size: 4
      )
    end

    now = Time.utc(2026, 11, 21, 12, 0, 0)
    on_server do
      shaped.create!(id: "m1", owner: "acme", state: "open", title: "Alpha invoice", created_at: now - 30, updated_at: now - 30)
      shaped.create!(id: "m2", owner: "acme", state: "open", title: "Beta hello", created_at: now - 20, updated_at: now - 20)
      shaped.create!(id: "m3", owner: "acme", state: "open", title: "Gamma invoice", created_at: now - 10, updated_at: now - 10)
      shaped.create!(id: "r3", owner: "acme", state: "reply", title: "m3", created_at: now - 5, updated_at: now - 5)
      shaped.create!(id: "c1", owner: "acme", state: "archived", title: "Archived invoice", created_at: now - 1, updated_at: now - 1)
    end

    base = InstantRecord::SyncScope.visible(shaped, nil, partition: "owner:acme")
    shape = shaped.instant_record_sync_shape

    boot = shape.bootstrap_records(base)
    assert_equal %w[m3 m2 r3], boot.map(&:id)

    page1 = shape.page(base, limit: 2)
    assert_equal %w[m3 m2 r3], page1[:records].map(&:id)
    assert_equal true, page1[:has_more]
    assert_equal "m2", page1[:next_before][:id]

    page2 = shape.page(base, before_at: Time.parse(page1[:next_before][:created_at]), before_id: page1[:next_before][:id], limit: 2)
    assert_equal %w[m1], page2[:records].map(&:id)
    assert_equal false, page2[:has_more]

    found = shape.page(base, search: "INVOICE")
    assert_equal %w[m3 m1 r3], found[:records].map(&:id)
    assert_equal false, found[:has_more]

    looked = shape.lookup(base, "m3")
    assert_equal %w[m3 r3], looked.map(&:id)

    assert_equal({ type: "ShapedMail", page_size: 4, partition: "acme" }, shape.fill_descriptor(partition: "acme"))
  end

  def test_client_sends_pluggable_auth_scope_partition_and_custom_headers_and_stores_fill_targets
    transport = HeaderCapturingTransport.new
    transport.bootstrap_response = {
      "cursor" => 7,
      "identity" => "abc123",
      "records" => [],
      "fill" => [{ "type" => "TenantItem", "page_size" => 200, "partition" => "acme" }]
    }
    InstantRecord::Client.transport = transport

    dynamic_token = "tok-1"
    InstantRecord.configure do |config|
      config.sync_scope = "visitor-9"
      config.sync_partition = { owner: "acme" }
      config.auth_token = "secret-jwt"
      config.headers = -> { { "X-Custom-Trace" => dynamic_token } }
    end

    expected_headers = {
      "X-Instant-Record-Scope" => "visitor-9",
      "X-Instant-Record-Partition" => "owner:acme",
      "Authorization" => "Bearer secret-jwt",
      "X-Custom-Trace" => "tok-1"
    }
    assert_equal expected_headers, InstantRecord::Client.request_headers

    in_browser do
      assert InstantRecord::Client.bootstrap
      assert_equal [{ "type" => "TenantItem", "page_size" => 200, "partition" => "acme" }], InstantRecord::Client.fill_targets

      @global.create!(id: "g-1", title: "queued")
      dynamic_token = "tok-2"
      assert InstantRecord::Client.drain
      InstantRecord::Client.poll_changes
    end

    boot_call = transport.calls.find { |kind, _| kind == :get }
    post_call = transport.calls.find { |kind, _| kind == :post }
    poll_call = transport.calls.find { |kind, _| kind == :events }

    assert_equal expected_headers, boot_call[2]
    assert_equal expected_headers.merge("X-Custom-Trace" => "tok-2"), post_call[3]
    assert_equal expected_headers.merge("X-Custom-Trace" => "tok-2"), poll_call[2]
  end

  def test_worker_fetch_formats_headers_safely_and_preserves_plain_wire_format_when_empty
    fetcher = InstantRecord::Client::Transport::WorkerFetch.new
    plain = fetcher.send(:format_request, "GET", "http://example.test/bootstrap", "", nil)
    assert_equal "GET http://example.test/bootstrap\n", plain

    with_headers = fetcher.send(
      :format_request,
      "POST",
      "http://example.test/mutations",
      '{"mutations":[]}',
      { "Authorization" => "Bearer abc\r\nInjected: bad", "X-Instant-Record-Partition" => "owner:acme" }
    )
    assert_equal(
      "POST http://example.test/mutations\nAuthorization: Bearer abcInjected: bad\nX-Instant-Record-Partition: owner:acme\n\n{\"mutations\":[]}",
      with_headers
    )
  end
end
