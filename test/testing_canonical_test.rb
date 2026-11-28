require "test_helper"
require "instant_record/testing"

class TestingCanonicalTest < Minitest::Test
  def reference_canonical_timestamp(value)
    time =
      if value.is_a?(Time)
        value.dup.utc
      else
        str = value.to_s.strip
        return nil if str.empty?

        if str.match?(/\A\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?\z/)
          Time.parse("#{str.tr(' ', 'T')}Z").utc
        else
          Time.parse(str).utc
        end
      end
    time.iso8601(InstantRecord::TIME_PRECISION)
  end

  def test_canonical_timestamp_handles_utc_variants_and_fractional_digits_0_to_12
    # Fractional lengths 0..12 including all-9s (must truncate like Time#iso8601(6), never carry over)
    (0..12).each do |n|
      nines = n == 0 ? "" : ".#{'9' * n}"
      seq = n == 0 ? "" : ".#{'123456789012'[0, n]}"
      zeros = n == 0 ? "" : ".#{'0' * n}"

      [
        "2026-11-21 23:59:59#{nines}",
        "2026-11-21T23:59:59#{nines}Z",
        "2026-11-21T23:59:59#{nines}z",
        "2026-11-21T23:59:59#{nines}+00:00",
        "2026-11-21T23:59:59#{nines}-00:00",
        "2026-11-21T23:59:59#{nines}+0000",
        "2026-11-21T23:59:59#{nines}-0000",
        "2026-11-21 10:20:30#{seq}",
        "2026-11-21T10:20:30#{seq}Z",
        "2026-11-21 00:00:00#{zeros}"
      ].each do |sample|
        assert_equal reference_canonical_timestamp(sample),
          InstantRecord::Testing.canonical_timestamp(sample),
          "mismatch for #{sample.inspect}"
      end
    end

    assert_equal "2026-11-21T23:59:59.999999Z",
      InstantRecord::Testing.canonical_timestamp("2026-11-21T23:59:59.9999999Z")
  end

  def test_canonical_timestamp_handles_leap_years_and_non_leap_years
    valid_leaps = [
      "2000-02-29 00:00:00",
      "2000-02-29T23:59:59.999999Z",
      "2024-02-29 12:34:56.789",
      "2024-02-29T12:34:56.789+00:00",
      "2024-02-29T23:30:00.123456-02:00"
    ]
    valid_leaps.each do |sample|
      assert_equal reference_canonical_timestamp(sample),
        InstantRecord::Testing.canonical_timestamp(sample),
        "mismatch for leap date #{sample.inspect}"
    end

    non_leaps = [
      "1900-02-29 12:00:00",
      "1900-02-29T12:00:00Z",
      "2025-02-29 12:00:00",
      "2025-02-29T12:00:00Z",
      "2025-02-29T12:00:00.123456+05:30",
      "2100-02-29 12:00:00"
    ]
    non_leaps.each do |sample|
      assert_equal reference_canonical_timestamp(sample),
        InstantRecord::Testing.canonical_timestamp(sample),
        "mismatch for non-leap date #{sample.inspect}"
    end
  end

  def test_canonical_timestamp_matches_time_parse_on_invalid_dates_and_leap_seconds
    wrapping_or_special = [
      "2026-02-30 12:00:00",
      "2026-04-31 00:00:00",
      "2026-01-01 24:00:00",
      "2026-01-01 12:00:60",
      "2026-01-01 23:59:60",
      "2026-11-21t22:04:08.123456",
      "2026-11-21t22:04:08.123456Z",
      "2026-11-21 22:04:08.123456 UTC",
      "  2026-11-21 22:04:08.123456  ",
      "\t2026-11-21T22:04:08.123456Z\n",
      "2026-11-21T22:04:08.123456Z".b
    ]
    wrapping_or_special.each do |sample|
      assert_equal reference_canonical_timestamp(sample),
        InstantRecord::Testing.canonical_timestamp(sample),
        "mismatch for #{sample.inspect}"
    end

    invalid_inputs = [
      "2026-00-01 00:00:00",
      "2026-13-01 00:00:00",
      "2026-01-00 00:00:00",
      "2026-01-32 00:00:00",
      "2026-01-01 25:00:00",
      "2026-01-01 12:60:00",
      "2026-01-01 12:00:61",
      "not-a-timestamp"
    ]
    invalid_inputs.each do |sample|
      ref_err = assert_raises(ArgumentError) { reference_canonical_timestamp(sample) }
      got_err = assert_raises(ArgumentError) { InstantRecord::Testing.canonical_timestamp(sample) }
      assert_equal ref_err.message, got_err.message, "error message mismatch for #{sample.inspect}"
    end
  end

  def test_canonical_timestamp_handles_non_utc_offsets_and_rollovers
    samples = [
      "2026-11-21T22:04:08.123456+05:30",
      "2026-11-21T22:04:08.123456-04:00",
      "2026-11-21T22:04:08.123456+0530",
      "2026-11-21T22:04:08.123456-0400",
      "2026-11-21T02:04:08.999999+05:30",
      "2026-11-21T22:04:08.000001-05:30",
      "2026-01-01T00:30:00.123456+02:00",
      "2026-12-31T23:30:00.123456-02:00",
      "2024-03-01T01:00:00.123456+03:00",
      "2025-03-01T01:00:00.123456+03:00",
      "0000-01-01T00:00:00.123456+01:00",
      "9999-12-31T23:59:59.999999-01:00",
      "2026-11-21T22:04:08.123456789+05:30",
      "2026-11-21T22:04:08.1+05:30",
      "2026-11-21T22:04:08+05:30"
    ]
    samples.each do |sample|
      assert_equal reference_canonical_timestamp(sample),
        InstantRecord::Testing.canonical_timestamp(sample),
        "mismatch for offset #{sample.inspect}"
    end
  end

  def test_canonical_timestamp_handles_time_objects_and_blanks
    assert_nil InstantRecord::Testing.canonical_timestamp(nil)
    assert_nil InstantRecord::Testing.canonical_timestamp("")
    assert_nil InstantRecord::Testing.canonical_timestamp("   \t\n  ")

    utc_time = Time.utc(2026, 11, 21, 22, 4, 8, 123_456)
    offset_time = Time.new(2026, 11, 21, 22, 4, 8, "+05:30")
    zero_offset_time = Time.new(2026, 11, 21, 22, 4, 8, "+00:00")
    sub_usec_time = Time.utc(2026, 11, 21, 22, 4, 8, Rational(9_999_999, 10))

    assert_equal "2026-11-21T22:04:08.123456Z", InstantRecord::Testing.canonical_timestamp(utc_time)
    assert_equal "2026-11-21T16:34:08.000000Z", InstantRecord::Testing.canonical_timestamp(offset_time)
    refute offset_time.utc?, "non-UTC Time argument should not be mutated in place"
    assert_equal "2026-11-21T22:04:08.000000Z", InstantRecord::Testing.canonical_timestamp(zero_offset_time)
    assert_equal "2026-11-21T22:04:08.999999Z", InstantRecord::Testing.canonical_timestamp(sub_usec_time)

    saved_zone = Time.zone
    begin
      Time.zone = "America/New_York"
      twz_ny = Time.zone.parse("2026-11-21 22:04:08.123456")
      assert_equal "2026-11-22T03:04:08.123456Z", InstantRecord::Testing.canonical_timestamp(twz_ny)

      Time.zone = "UTC"
      twz_utc = Time.zone.parse("2026-11-21 22:04:08.123456")
      assert_equal "2026-11-21T22:04:08.123456Z", InstantRecord::Testing.canonical_timestamp(twz_utc)
    ensure
      Time.zone = saved_zone
    end
  end

  def test_canonical_value_handles_encodings_types_and_nils
    assert_nil InstantRecord::Testing.canonical_value("title", nil)
    assert_nil InstantRecord::Testing.canonical_value("created_at", nil)
    assert_nil InstantRecord::Testing.canonical_value("server_version", nil)

    assert_equal 42, InstantRecord::Testing.canonical_value("server_version", "42")
    assert_equal 42, InstantRecord::Testing.canonical_value(:server_version, 42)
    assert_equal 7, InstantRecord::Testing.canonical_value("word_count", "7")
    assert_equal 3, InstantRecord::Testing.canonical_value("revision", "3")
    assert_equal true, InstantRecord::Testing.canonical_value("done", true)
    assert_equal false, InstantRecord::Testing.canonical_value("done", false)
    assert_equal 99, InstantRecord::Testing.canonical_value("score", 99)

    utf8 = "héllo".encode(Encoding::UTF_8)
    out_utf8 = InstantRecord::Testing.canonical_value("title", utf8)
    assert_equal utf8, out_utf8
    assert_equal Encoding::UTF_8, out_utf8.encoding

    us_ascii = "plain".encode(Encoding::US_ASCII)
    out_ascii = InstantRecord::Testing.canonical_value("title", us_ascii)
    assert_equal "plain", out_ascii
    assert_equal Encoding::UTF_8, out_ascii.encoding

    latin1 = "caf\xE9".b.force_encoding(Encoding::ISO_8859_1)
    out_latin1 = InstantRecord::Testing.canonical_value("title", latin1)
    assert_equal "café", out_latin1
    assert_equal Encoding::UTF_8, out_latin1.encoding

    # Invalid UTF-8 byte sequence matches String#encode(Encoding::UTF_8) no-op behavior
    bad_utf8 = "\xFF".b.force_encoding(Encoding::UTF_8)
    assert_equal bad_utf8.encode(Encoding::UTF_8), InstantRecord::Testing.canonical_value("title", bad_utf8)

    # Non-ASCII BINARY raises UndefinedConversionError just like String#encode(Encoding::UTF_8)
    assert_raises(Encoding::UndefinedConversionError) do
      InstantRecord::Testing.canonical_value("title", "\xFF".b)
    end
  end

  def test_canonical_rows_handles_mixed_keys_duplicates_heterogeneous_schemas_and_custom_exclusions
    assert_equal [], InstantRecord::Testing.canonical_rows(nil)
    assert_equal [], InstantRecord::Testing.canonical_rows([])

    # Mixed key order + mixed Time/String timestamps + nil values
    mixed = [
      { "updated_at" => "2026-11-21T10:00:00.000001Z", "id" => "b", "title" => nil, "sync_state" => "pending", "word_count" => "5" },
      { "id" => "a", "title" => "One", "word_count" => 2, "updated_at" => Time.utc(2026, 11, 21, 10, 0, 0, 0), "sync_state" => "synced" }
    ]
    rows = InstantRecord::Testing.canonical_rows(mixed)
    assert_equal %w[a b], rows.map { |r| r["id"] }
    assert_equal [%w[id title updated_at word_count], %w[id title updated_at word_count]], rows.map(&:keys)
    assert_equal "2026-11-21T10:00:00.000000Z", rows[0]["updated_at"]
    assert_nil rows[1]["title"]
    assert_equal 5, rows[1]["word_count"]

    # Symbol vs String keys across rows
    sym_and_str = [
      { id: "2", title: "B", sync_state: "synced", updated_at: "2026-11-21 10:00:00" },
      { "id" => "1", "title" => "A", "sync_state" => "synced", "updated_at" => "2026-11-21 09:00:00" }
    ]
    normalized_sym = InstantRecord::Testing.canonical_rows(sym_and_str)
    assert_equal %w[1 2], normalized_sym.map { |r| r["id"] }
    assert_equal %w[id title updated_at], normalized_sym[0].keys
    assert_equal %w[id title updated_at], normalized_sym[1].keys

    # Duplicate-after-to_s keys: last key in iteration order wins
    dups = [
      { "id" => "1", "title" => "first", title: "second", "sync_state" => "synced" },
      { "id" => "2", title: "first_sym", "title" => "second_str", "sync_state" => "synced" }
    ]
    normalized_dups = InstantRecord::Testing.canonical_rows(dups)
    assert_equal "second", normalized_dups[0]["title"]
    assert_equal "second_str", normalized_dups[1]["title"]

    # Heterogeneous columns
    hetero = [
      { "id" => "2", "b" => 2, "a" => 1, "sync_state" => "synced" },
      { "id" => "1", "c" => 3, "a" => 1, "sync_state" => "synced" }
    ]
    normalized_hetero = InstantRecord::Testing.canonical_rows(hetero)
    assert_equal [%w[a c id], %w[a b id]], normalized_hetero.map(&:keys)

    # Custom exclude_columns (symbols, multiple, and empty)
    custom = InstantRecord::Testing.canonical_rows(
      [{ "id" => "1", "title" => "A", "updated_at" => "2026-11-21 10:00:00", "sync_state" => "pending" }],
      exclude_columns: [:sync_state, :updated_at]
    )
    assert_equal [{ "id" => "1", "title" => "A" }], custom

    keep_all = InstantRecord::Testing.canonical_rows(
      [{ "id" => "1", "sync_state" => "pending", "title" => "A" }],
      exclude_columns: []
    )
    assert_equal [{ "id" => "1", "sync_state" => "pending", "title" => "A" }], keep_all
    assert_equal %w[id sync_state title], keep_all[0].keys
  end

  def test_canonical_json_sorts_nested_structures_deterministically
    a = {
      "tables" => {
        "Issue" => [
          { "title" => "Two", "id" => "2", "meta" => { z: 1, a: 2 } },
          { "id" => "1", "meta" => { "a" => 2, "z" => 1 }, "title" => "One" }
        ]
      },
      "cursor" => 10
    }
    b = {
      cursor: 10,
      tables: {
        Issue: [
          { id: "2", meta: { a: 2, z: 1 }, title: "Two" },
          { title: "One", id: "1", meta: { z: 1, a: 2 } }
        ]
      }
    }

    assert_equal InstantRecord::Testing.canonical_json(a), InstantRecord::Testing.canonical_json(b)
    assert_equal JSON.pretty_generate({}), InstantRecord::Testing.canonical_json({})
    assert_equal JSON.pretty_generate([]), InstantRecord::Testing.canonical_json([])

    # Mixed string and symbol colliding key matches String-key preference
    assert_equal "{\n  \"a\": 1,\n  \"b\": 3\n}", InstantRecord::Testing.canonical_json({ "a" => 1, a: 2, b: 3 })
  end
end
