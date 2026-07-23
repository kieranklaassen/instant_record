require "test_helper"

# Transport double local to this file so it runs standalone.
class HistoryTransport
  attr_reader :history_requests
  attr_accessor :pages, :fail_requests

  def initialize
    @history_requests = []
    @pages = []
  end

  def get_json(path)
    @history_requests << path
    raise InstantRecord::Client::Transport::Error, "offline" if fail_requests

    @pages.shift || { "records" => [], "has_more" => false }
  end
end

class FetchHistoryTest < Minitest::Test
  def setup
    @model = syncable_model("Memo") { sync_window limit: 2, partition_by: :state }
    InstantRecord.sync(@model)
    @transport = HistoryTransport.new
    InstantRecord::Client.transport = @transport
    reset_instant_record_tables!
    InstantRecord::Client.instance_variable_set(:@history_marks, nil)
    InstantRecord.instance_variable_set(:@ticking, false)
  end

  def teardown
    InstantRecord.sync
    InstantRecord::Client.transport = nil
    InstantRecord::Client.instance_variable_set(:@history_marks, nil)
    InstantRecord.instance_variable_set(:@ticking, false)
  end

  def record_payload(id, at)
    { "type" => "Memo", "id" => id, "version" => 1,
      "attributes" => { "id" => id, "title" => id, "state" => "a",
                        "created_at" => at.iso8601(6), "updated_at" => at.iso8601(6) } }
  end

  def before_cursor(at)
    { created_at: at.iso8601(6), id: "zz-boundary" }
  end

  def test_fetch_applies_rows_locally_without_outbox_noise
    now = Time.now.utc
    @transport.pages = [{ "records" => [record_payload("m-2", now - 120), record_payload("m-1", now - 180)],
                          "has_more" => true }]

    result = in_browser { InstantRecord.fetch_history(@model, partition: "a", before: before_cursor(now)) }

    assert result[:ok]
    assert_equal 2, result[:applied]
    assert result[:has_more]
    assert_equal %w[m-1 m-2], @model.order(:id).pluck(:id)
    assert_equal 0, InstantRecord::OutboxMutation.count
    assert_includes @transport.history_requests.sole, "type=Memo"
    assert_includes @transport.history_requests.sole, "partition=a"
  end

  def test_repeat_page_above_the_mark_is_served_locally
    now = Time.now.utc
    @transport.pages = [{ "records" => [record_payload("m-2", now - 120), record_payload("m-1", now - 180)],
                          "has_more" => true }]

    in_browser do
      InstantRecord.fetch_history(@model, partition: "a", before: before_cursor(now))
      result = InstantRecord.fetch_history(@model, partition: "a", before: before_cursor(now))

      assert result[:ok]
      assert_equal 0, result[:applied], "already-local page must not re-apply"
      assert result[:has_more]
    end

    assert_equal 1, @transport.history_requests.size, "repeat scroll must not refetch"
  end

  def test_page_without_a_recorded_mark_fetches_even_when_rows_exist_locally
    now = Time.now.utc
    on_server do
      @model.create!(id: "stray-1", state: "a", created_at: now - 300, updated_at: now - 300)
      @model.create!(id: "stray-2", state: "a", created_at: now - 240, updated_at: now - 240)
    end

    in_browser { InstantRecord.fetch_history(@model, partition: "a", before: before_cursor(now)) }

    assert_equal 1, @transport.history_requests.size,
      "row count alone cannot prove contiguity; without a mark the page must fetch"
  end

  def test_stray_rows_below_the_mark_still_fetch_from_the_server
    now = Time.now.utc
    # First page establishes a contiguity mark at (now-180).
    @transport.pages = [{ "records" => [record_payload("m-2", now - 120), record_payload("m-1", now - 180)],
                          "has_more" => true }]

    in_browser do
      first = before_cursor(now)
      InstantRecord.fetch_history(@model, partition: "a", before: first)

      # Stray rows appear locally BELOW the mark (e.g. a live update re-created
      # an evicted row). Count alone would look contiguous; the mark guard
      # must still fetch the gap page.
      InstantRecord::Client.applying_remote do
        @model.create!(id: "stray-a", state: "a", created_at: now - 600, updated_at: now - 600)
        @model.create!(id: "stray-b", state: "a", created_at: now - 660, updated_at: now - 660)
      end
      @transport.pages = [{ "records" => [record_payload("m-0", now - 240)], "has_more" => true }]

      # Request the page below the mark boundary (m-1 @ now-180).
      InstantRecord.fetch_history(@model, partition: "a", before: { created_at: (now - 180).iso8601(6), id: "m-1" })
    end

    assert_equal 2, @transport.history_requests.size,
      "a page at/below the contiguity frontier must fetch, not serve the stray local rows"
  end

  def test_beginning_of_history_serves_locally_forever_after
    now = Time.now.utc
    @transport.pages = [{ "records" => [record_payload("m-1", now - 120)], "has_more" => false }]

    in_browser do
      first = InstantRecord.fetch_history(@model, partition: "a", before: before_cursor(now))
      refute first[:has_more]

      again = InstantRecord.fetch_history(@model, partition: "a", before: before_cursor(now))
      assert again[:ok]
      refute again[:has_more]
    end

    assert_equal 1, @transport.history_requests.size
  end

  def test_busy_while_a_tick_is_in_flight
    InstantRecord.instance_variable_set(:@ticking, true)

    result = in_browser { InstantRecord.fetch_history(@model, partition: "a", before: before_cursor(Time.now.utc)) }

    assert_equal :busy, result
    assert_empty @transport.history_requests
  ensure
    InstantRecord.instance_variable_set(:@ticking, false)
  end

  def test_tick_is_busy_while_a_history_fetch_is_in_flight
    nested_tick = nil
    @transport.define_singleton_method(:get_json) do |_path|
      nested_tick = InstantRecord.tick
      { "records" => [], "has_more" => false }
    end
    InstantRecord.instance_variable_set(:@started, true)

    in_browser { InstantRecord.fetch_history(@model, partition: "a", before: before_cursor(Time.now.utc)) }

    assert_equal :busy, nested_tick
  ensure
    InstantRecord.instance_variable_set(:@started, false)
  end

  def test_offline_surfaces_as_an_error_return_not_an_exception
    @transport.fail_requests = true

    result = in_browser { InstantRecord.fetch_history(@model, partition: "a", before: before_cursor(Time.now.utc)) }

    refute result[:ok]
    assert_match(/offline/, result[:error])
  end

  def test_server_runtime_is_a_pure_local_query
    now = Time.now.utc
    on_server do
      @model.create!(id: "old-1", state: "a", created_at: now - 300, updated_at: now - 300)
      @model.create!(id: "old-2", state: "a", created_at: now - 240, updated_at: now - 240)
      @model.create!(id: "old-3", state: "a", created_at: now - 180, updated_at: now - 180)

      result = InstantRecord.fetch_history(@model, partition: "a", before: before_cursor(now), limit: 2)

      assert result[:ok]
      assert_equal 0, result[:applied]
      assert result[:has_more], "a third row remains below the two-row page"
    end

    assert_empty @transport.history_requests
  end

  def test_windowless_model_raises
    plain = syncable_model("PlainItem")
    assert_raises(ArgumentError) do
      on_server { InstantRecord.fetch_history(plain, before: before_cursor(Time.now.utc)) }
    end
  end

  def test_fetch_history_json_round_trips
    now = Time.now.utc
    @transport.pages = [{ "records" => [record_payload("m-1", now - 120)], "has_more" => false }]
    request = JSON.generate(type: "Memo", partition: "a",
      before: { created_at: now.iso8601(6), id: "zz-boundary" })

    reply = in_browser { JSON.parse(InstantRecord.fetch_history_json(request)) }

    assert reply["ok"]
    assert_equal 1, reply["applied"]
    assert_equal false, reply["has_more"]
    assert_equal %w[m-1], @model.pluck(:id)
  end

  def test_fetch_history_json_unknown_type_is_a_json_error
    reply = JSON.parse(InstantRecord.fetch_history_json(JSON.generate(type: "Nope", before: {})))

    refute reply["ok"]
    assert_match(/Nope/, reply["error"])
  end

  def test_fetch_history_json_malformed_input_is_a_json_error
    reply = JSON.parse(InstantRecord.fetch_history_json("not json"))

    refute reply["ok"]
    assert reply["error"]
  end

  def test_fetch_history_json_busy_flags_for_the_retry_loop
    InstantRecord.instance_variable_set(:@ticking, true)
    request = JSON.generate(type: "Memo", partition: "a",
      before: { created_at: Time.now.utc.iso8601(6), id: "x" })

    reply = JSON.parse(in_browser { InstantRecord.fetch_history_json(request) })

    refute reply["ok"]
    assert reply["busy"]
  ensure
    InstantRecord.instance_variable_set(:@ticking, false)
  end

  def test_fetch_history_b64_decodes_and_delegates
    now = Time.now.utc
    @transport.pages = [{ "records" => [record_payload("m-1", now - 120)], "has_more" => false }]
    request = JSON.generate(type: "Memo", partition: "a",
      before: { created_at: now.iso8601(6), id: "zz-boundary" })

    reply = in_browser { JSON.parse(InstantRecord.fetch_history_b64(Base64.strict_encode64(request))) }

    assert reply["ok"]
    assert_equal %w[m-1], @model.pluck(:id)
  end

  # The whole reason fetch_history_b64 exists: an untrusted page message must
  # not become Ruby source. A field carrying #{...} would be interpolated if
  # the request entered evalAsync as raw text; base64 has none of Ruby's
  # string-literal metacharacters, so it round-trips as inert data.
  def test_fetch_history_b64_neutralizes_ruby_interpolation
    malicious = JSON.generate(type: 'Memo#{system("touch /tmp/pwned")}', before: {})

    reply = in_browser { JSON.parse(InstantRecord.fetch_history_b64(Base64.strict_encode64(malicious))) }

    refute reply["ok"], "an unknown/hostile type must be rejected, not evaluated"
    refute File.exist?("/tmp/pwned"), "no interpolation side effect"
  ensure
    File.delete("/tmp/pwned") if File.exist?("/tmp/pwned")
  end

  def test_fetch_history_b64_rejects_malformed_base64
    reply = JSON.parse(InstantRecord.fetch_history_b64("not valid base64!!!"))

    refute reply["ok"]
    assert reply["error"]
  end
end
