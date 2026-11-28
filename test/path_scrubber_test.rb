require "test_helper"
require "tmpdir"
require "pathname"
require "digest"
require "instant_record/compiler/path_scrubber"

class PathScrubberTest < Minitest::Test
  CHUNK_SIZE = InstantRecord::Compiler::PathScrubber::CHUNK_SIZE

  def reference_scrub(data, prefix)
    prefix_bytes = prefix.to_s.b
    raise ArgumentError, "prefix must not be empty" if prefix_bytes.empty?

    neutral = ("/build" + "/_" * prefix_bytes.bytesize).byteslice(0, prefix_bytes.bytesize).b
    count = 0
    patched = data.b.gsub(prefix_bytes) do
      count += 1
      neutral
    end
    remaining = patched.include?(prefix_bytes) ? patched.scan(prefix_bytes).length : 0
    [patched, { count: count, remaining: remaining, size: patched.bytesize }]
  end

  def assert_scrub_parity(data, prefix, msg = nil)
    expected_bytes, expected_result = reference_scrub(data, prefix)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "fixture.wasm")
      File.binwrite(path, data.b)

      actual_result = InstantRecord::Compiler::PathScrubber.scrub(path, prefix)
      actual_bytes = File.binread(path)

      label = msg || "prefix=#{prefix.inspect}"
      assert_equal expected_result, actual_result, "return hash mismatch (#{label})"
      assert_equal expected_bytes.bytesize, actual_bytes.bytesize, "size mismatch (#{label})"
      assert_equal Digest::SHA256.hexdigest(expected_bytes), Digest::SHA256.hexdigest(actual_bytes),
        "scrubbed bytes mismatch (#{label})"
      actual_result
    end
  end

  def test_empty_or_nil_prefix_raises_argument_error_before_opening_file
    ["", nil, "".b].each do |bad_prefix|
      err = assert_raises(ArgumentError) do
        InstantRecord::Compiler::PathScrubber.scrub("/nonexistent/path/app.wasm", bad_prefix)
      end
      assert_equal "prefix must not be empty", err.message
    end
  end

  def test_file_error_semantics
    Dir.mktmpdir do |dir|
      missing = File.join(dir, "missing.wasm")
      assert_raises(Errno::ENOENT) do
        InstantRecord::Compiler::PathScrubber.scrub(missing, "/src/app")
      end

      assert_raises(Errno::EISDIR) do
        InstantRecord::Compiler::PathScrubber.scrub(dir, "/src/app")
      end

      # Read-only file must raise EACCES both when matches exist and when count == 0
      ro_match = File.join(dir, "ro_match.wasm")
      ro_empty = File.join(dir, "ro_empty.wasm")
      File.binwrite(ro_match, "/src/app/main.rb".b)
      File.binwrite(ro_empty, "no-matches-here".b)
      File.chmod(0o444, ro_match)
      File.chmod(0o444, ro_empty)
      begin
        if Process.euid != 0
          assert_raises(Errno::EACCES) { InstantRecord::Compiler::PathScrubber.scrub(ro_match, "/src/app") }
          assert_raises(Errno::EACCES) { InstantRecord::Compiler::PathScrubber.scrub(ro_empty, "/src/app") }
        end
      ensure
        File.chmod(0o644, ro_match)
        File.chmod(0o644, ro_empty)
      end

      # Write-only file must raise EACCES
      wo_file = File.join(dir, "wo.wasm")
      File.binwrite(wo_file, "/src/app/main.rb".b)
      File.chmod(0o222, wo_file)
      begin
        if Process.euid != 0
          assert_raises(Errno::EACCES) { InstantRecord::Compiler::PathScrubber.scrub(wo_file, "/src/app") }
        end
      ensure
        File.chmod(0o644, wo_file)
      end
    end
  end

  def test_empty_file_and_file_shorter_than_prefix
    assert_scrub_parity("", "/var/tmp/build-root")
    assert_scrub_parity("/var", "/var/tmp/build-root")
    assert_scrub_parity("\x00asm\x01".b, "/var/tmp/build-root")
  end

  def test_accepts_pathname_and_preserves_zero_match_content
    Dir.mktmpdir do |dir|
      path = Pathname(dir).join("app.wasm")
      payload = ("\x00asm\x01\x00\x00\x00" + "payload-without-prefix").b
      File.binwrite(path, payload)

      result = InstantRecord::Compiler::PathScrubber.scrub(path, "/var/tmp/build-root")
      assert_equal({ count: 0, remaining: 0, size: payload.bytesize }, result)
      assert_equal payload, File.binread(path)
    end
  end

  def test_neutral_bytes_exact_for_short_medium_and_long_prefixes
    ((1..20).to_a + [43, 44, 1024, 1025, 1500]).each do |len|
      prefix = ("X" * len).b
      data = ("AA".b + prefix + "BB".b + prefix + "CC".b)
      assert_scrub_parity(data, prefix, "length=#{len}")
    end
  end

  def test_self_matching_neutral_prefixes
    %w[/ /b /bu /bui /buil /build /build/ /build/_ /build/_/ /build/_/_].each do |prefix|
      data = ("xx" + prefix + "yy" + prefix + prefix + "zz").b
      assert_scrub_parity(data, prefix)
    end
  end

  def test_overlapping_and_adjacent_matches_left_to_right
    assert_scrub_parity("ababa", "aba")
    assert_scrub_parity("abababa", "aba")
    assert_scrub_parity("aaaaa", "aa")
    assert_scrub_parity("aaaaaa", "aa")
    assert_scrub_parity("/src/app/src/app/src/app", "/src/app")
  end

  def test_replacement_creating_new_prefix_occurrences
    # Right-boundary overlap: neutral ends with "/" and prefix starts with "/"
    assert_scrub_parity("/abc/deabc/de", "/abc/de")
    assert_scrub_parity("/abc/deabc/deabc/de", "/abc/de")

    # Left-boundary overlap: prefix ends with "/" and neutral starts with "/"
    assert_scrub_parity("abab/", "ab/")
    assert_scrub_parity("ab/ab/", "ab/")
    assert_scrub_parity("xx/b", "x/b")
    assert_scrub_parity("/build/build/_", "build/")
    assert_scrub_parity("/build/_", "/_")

    # Both left and right boundary overlap
    assert_scrub_parity("/build/x/build/x", "build/x/")
    assert_scrub_parity("x/build/x/b", "/build/x/")
  end

  def test_binary_nul_bytes_high_bytes_regex_metachars_and_utf8
    binary = (0..255).to_a.pack("C*")
    prefix = "/var/tmp/[build]+(a.b)?*$^\\".b
    data = binary + prefix + "\x00\xFF\xFE".b + prefix + binary
    assert_scrub_parity(data, prefix)

    # Prefix containing NUL bytes and high bytes
    bin_prefix = "\x00/src/\xFF\x00".b
    assert_scrub_parity("\x01".b + bin_prefix + "\x02".b + bin_prefix, bin_prefix)

    # UTF-8 multibyte prefix converted via prefix.to_s.b
    utf8_prefix = "/var/tmp/caf\u00E9-build"
    assert_scrub_parity(("hdr\x00".b + utf8_prefix.b + "/app.rb".b), utf8_prefix)
  end

  def test_chunk_boundary_crossings_and_exact_multiples
    prefix = "/var/tmp/build-root/app".b # length 23 (odd -> neutral ends with "/")
    plen = prefix.bytesize

    # Exact boundary placements around CHUNK_SIZE
    [
      CHUNK_SIZE - plen,
      CHUNK_SIZE - plen + 1,
      CHUNK_SIZE - (plen / 2),
      CHUNK_SIZE - 1,
      CHUNK_SIZE
    ].each do |offset|
      data = ("." * (CHUNK_SIZE + 128)).b
      data[offset, plen] = prefix
      assert_scrub_parity(data, prefix, "boundary offset=#{offset}")
    end

    # Match ending right at CHUNK_SIZE - 1 followed immediately by partial prefix at CHUNK_SIZE
    data = ("." * (CHUNK_SIZE + 64)).b
    data[CHUNK_SIZE - plen, plen] = prefix
    data[CHUNK_SIZE, plen - 1] = prefix.byteslice(1, plen - 1)
    res = assert_scrub_parity(data, prefix, "adjacent to boundary")
    assert_equal 1, res[:count]
    assert_equal 1, res[:remaining]

    # Seam match immediately followed by another match in the second chunk
    data2 = ("." * (CHUNK_SIZE + 128)).b
    seam_off = CHUNK_SIZE - 5
    data2[seam_off, plen] = prefix
    data2[seam_off + plen, plen] = prefix
    assert_scrub_parity(data2, prefix, "seam followed by adjacent match")

    # Exact file sizes around CHUNK_SIZE multiples
    [CHUNK_SIZE - 1, CHUNK_SIZE, CHUNK_SIZE + 1, 2 * CHUNK_SIZE].each do |fsize|
      buf = ("." * fsize).b
      buf[0, plen] = prefix
      buf[fsize - plen, plen] = prefix
      assert_scrub_parity(buf, prefix, "file_size=#{fsize}")
    end
  end

  def test_dense_matches_across_chunks_with_and_without_remaining
    # Odd-length prefix creating remaining matches across chunk boundaries in dense chunks
    odd_prefix = "/abc/de".b
    unit = "/abc/deabc/de".b # replacing first creates 1 remaining match
    chunk_dense = (unit * 100) + ("." * (CHUNK_SIZE - unit.bytesize * 100 - 3))
    data = (chunk_dense + odd_prefix + (unit * 80) + "tail").b
    assert_scrub_parity(data, odd_prefix, "dense odd with remaining across seam")

    # Dense matches with no remaining matches (even-length prefix, neutral ends with "_")
    even_prefix = "/var/tmp/build-root/src1".b
    block = (even_prefix + "____").b
    dense_even = (block * ((CHUNK_SIZE / block.bytesize) + 50)).b
    assert_scrub_parity(dense_even, even_prefix, "dense even across multiple chunks")

    # Dense matches with odd-length prefix where remaining == 0 (exercises in-memory dense check fast path)
    odd_no_rem = "/var/tmp/build-root/src".b
    block_odd = (odd_no_rem + "XXXX").b
    dense_odd_clean = (block_odd * ((CHUNK_SIZE / block_odd.bytesize) + 50)).b
    assert_scrub_parity(dense_odd_clean, odd_no_rem, "dense odd clean across multiple chunks")

    # Dense self-matching neutral prefix across chunks
    self_prefix = "/build/_".b
    dense_self = (self_prefix * ((CHUNK_SIZE / self_prefix.bytesize) + 50)).b
    assert_scrub_parity(dense_self, self_prefix, "dense self-matching neutral")
  end

  def test_dense_chunk_with_seam_match_and_left_boundary_overlap
    # Prefix "ab/" has left-boundary overlap with neutral "/bu" (delta_start = -2, delta_end = 1)
    prefix = "ab/".b
    # Place a seam match crossing CHUNK_SIZE and dense matches right at the start of chunk 2
    data = ("." * (CHUNK_SIZE - 2) + "ab/abab/" + ("ab/." * 60)).b
    assert_scrub_parity(data, prefix, "left-boundary overlap across seam into dense chunk")
  end

  def test_prefix_longer_than_exact_overlap_limit_and_chunk_size
    # Longer than EXACT_OVERLAP_MAX_LEN (1024) with overlapping replacement creating a new match
    long_prefix = ("/" + "a" * 1199 + "/").b # length 1201 (odd -> neutral ends with "/")
    data = (long_prefix + long_prefix.byteslice(1, long_prefix.bytesize - 1) + "end").b
    assert_scrub_parity(data, long_prefix, "len=1201 > EXACT_OVERLAP_MAX_LEN")

    # Longer than CHUNK_SIZE (524_288)
    huge_prefix = ("/var/tmp/" + "z" * (CHUNK_SIZE + 64)).b
    huge_data = ("HDR".b + huge_prefix + "MID".b + huge_prefix + "END".b)
    assert_scrub_parity(huge_data, huge_prefix, "prefix > CHUNK_SIZE")
  end

  def test_randomized_differential_parity_over_adversarial_alphabet
    rng = Random.new(20261128)
    alphabet = %w[/ b u i l d _ a]

    Dir.mktmpdir do |dir|
      path = File.join(dir, "fuzz.bin")
      150.times do |i|
        plen = rng.rand(1..12)
        prefix = Array.new(plen) { alphabet[rng.rand(alphabet.length)] }.join.b
        dlen = rng.rand(0..120)
        data = Array.new(dlen) { alphabet[rng.rand(alphabet.length)] }.join.b

        expected_bytes, expected_result = reference_scrub(data, prefix)
        File.binwrite(path, data)
        actual_result = InstantRecord::Compiler::PathScrubber.scrub(path, prefix)
        actual_bytes = File.binread(path)

        assert_equal expected_result, actual_result, "fuzz case #{i} prefix=#{prefix.inspect}"
        assert_equal expected_bytes, actual_bytes, "fuzz bytes case #{i} prefix=#{prefix.inspect}"
      end
    end
  end

  def test_pread_all_pwrite_all_and_multi_chunk_range_counting
    scrubber = InstantRecord::Compiler::PathScrubber

    # pread_all handles short reads and raises BuildError on EOFError or empty read
    short_reader = Object.new
    short_reader.define_singleton_method(:pread) do |len, offset, buf = nil|
      source = "abcdefghij".b
      raise EOFError, "end of file reached" if offset >= source.bytesize

      slice = source.byteslice(offset, [len, 3].min)
      buf ? buf.replace(slice) : slice
    end
    assert_equal "cdefgh".b, scrubber.send(:pread_all, short_reader, 6, 2, String.new(encoding: Encoding::BINARY))
    err = assert_raises(InstantRecord::Compiler::BuildError) do
      scrubber.send(:pread_all, short_reader, 6, 8, String.new(encoding: Encoding::BINARY))
    end
    assert_match(/unexpected EOF/, err.message)

    # pwrite_all loops on partial writes and raises BuildError on non-positive write
    written = "".b
    partial_writer = Object.new
    partial_writer.define_singleton_method(:pwrite) do |bytes, _offset|
      n = [bytes.bytesize, 2].min
      written << bytes.byteslice(0, n)
      n
    end
    assert_equal 5, scrubber.send(:pwrite_all, partial_writer, "hello".b, 0)
    assert_equal "hello".b, written

    stalled_writer = Object.new
    stalled_calls = 0
    stalled_writer.define_singleton_method(:pwrite) do |_bytes, _offset|
      stalled_calls += 1
      stalled_calls == 1 ? 1 : 0
    end
    write_err = assert_raises(InstantRecord::Compiler::BuildError) do
      scrubber.send(:pwrite_all, stalled_writer, "hello".b, 0)
    end
    assert_match(/short write/, write_err.message)

    # Multi-chunk count_occurrences_in_range with matches across read_size seams
    Dir.mktmpdir do |dir|
      path = File.join(dir, "window.bin")
      prefix = "/abc/de".b
      # Place occurrences at offsets 0, 7 (across read_size=10 seam), and 16
      payload = (prefix + prefix + "xx" + prefix + "yy").b
      File.binwrite(path, payload)
      File.open(path, "rb") do |io|
        count = scrubber.send(
          :count_occurrences_in_range,
          io, prefix, 0, payload.bytesize, 10,
          String.new(encoding: Encoding::BINARY),
          String.new(encoding: Encoding::BINARY)
        )
        assert_equal 3, count
      end
    end
  end
end
