require "test_helper"
require "tmpdir"
require "stringio"
require "rack/mock"
require "rack/request"

class FileStoreTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("instant-record-files")
    @store = InstantRecord::FileStore.new(@root)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def append(bytes, at:, key: "clip/one", upload: "first")
    @store.append(key, upload, StringIO.new(bytes), at: at, length: bytes.bytesize)
  end

  def stub_singleton(target, method_name, replacement)
    singleton = target.singleton_class
    had_own = singleton.method_defined?(method_name, false)
    original = target.method(method_name)
    singleton.remove_method(method_name) if had_own
    singleton.define_method(method_name) { |*args, **kwargs, &block| replacement.call(*args, **kwargs, &block) }
    yield
  ensure
    singleton.remove_method(method_name) if singleton.method_defined?(method_name, false)
    singleton.define_method(method_name, original) if had_own
  end

  def serve(key, method: "GET", headers: {})
    env = Rack::MockRequest.env_for("/#{key}", { method: method }.merge(headers))
    status, response_headers, response_body = @store.serve(key, Rack::Request.new(env))
    bytes = +""
    response_body.each { |part| bytes << part }
    response_body.close if response_body.respond_to?(:close)
    [status, response_headers, bytes]
  end

  def test_pieces_make_the_file_when_the_last_one_lands
    assert_equal 5, append("hello", at: 0)
    refute @store.exist?("clip/one"), "a partial is not the record's file"
    assert_equal 5, @store.offset("clip/one", "first")

    assert_equal 11, append(" world", at: 5)
    @store.finish("clip/one", "first")

    assert @store.exist?("clip/one")
    assert_equal 11, @store.size("clip/one")
    assert_equal "hello world", File.binread(@store.path("clip/one"))
    assert_equal 0, @store.offset("clip/one", "first"), "the partial became the file"
  end

  def test_a_piece_out_of_turn_is_refused_and_says_where_to_go_on
    append("hello", at: 0)

    again = assert_raises(InstantRecord::FileStore::Misplaced) { append("hello", at: 0) }
    assert_equal 5, again.offset
    ahead = assert_raises(InstantRecord::FileStore::Misplaced) { append("!", at: 9) }
    assert_equal 5, ahead.offset
    assert_equal 5, @store.offset("clip/one", "first"), "neither wrote anything"
  end

  def test_a_piece_cut_short_is_dropped_whole
    append("hello", at: 0)

    cut = assert_raises(InstantRecord::FileStore::Misplaced) do
      @store.append("clip/one", "first", StringIO.new("wor"), at: 5, length: 6)
    end
    assert_equal 5, cut.offset
    assert_equal 5, @store.offset("clip/one", "first")
  end

  def test_a_read_error_drops_the_piece_and_allows_retry
    append("hello", at: 0)
    failure = IOError.new("upload disconnected")
    source = Object.new
    reads = 0
    source.define_singleton_method(:read) do |length, buffer|
      reads += 1
      raise failure if reads > 1

      buffer.replace(" wo")
    end

    error = assert_raises(IOError) do
      @store.append("clip/one", "first", source, at: 5, length: 6)
    end
    assert_same failure, error
    assert_equal 5, @store.offset("clip/one", "first")
    assert_equal 11, append(" world", at: 5)
    @store.finish("clip/one", "first")
    assert_equal "hello world", File.binread(@store.path("clip/one"))
  end

  def test_a_flush_error_drops_the_piece_and_allows_retry
    append("hello", at: 0)
    failure = IOError.new("flush failed")
    original_open = File.method(:open)
    wrapped_open = lambda do |*args, &block|
      original_open.call(*args) do |file|
        file.define_singleton_method(:fsync) { raise failure }
        block.call(file)
      end
    end

    stub_singleton(File, :open, wrapped_open) do
      error = assert_raises(IOError) { append(" world", at: 5) }
      assert_same failure, error
    end

    refute_includes File.singleton_methods(false), :open
    assert_equal 5, @store.offset("clip/one", "first")
    assert_equal 11, append(" world", at: 5)
    @store.finish("clip/one", "first")
    assert_equal "hello world", File.binread(@store.path("clip/one"))
  end

  def test_two_uploads_of_one_record_do_not_mix
    append("aaaa", at: 0, upload: "first")
    append("bb", at: 0, upload: "second")
    append("bb", at: 2, upload: "second")

    @store.finish("clip/one", "second")
    assert_equal "bbbb", File.binread(@store.path("clip/one"))

    # The first to finish wins: the file is never written again.
    @store.finish("clip/one", "first")
    assert_equal "bbbb", File.binread(@store.path("clip/one"))
    assert_equal 0, @store.offset("clip/one", "first")
  end

  def test_an_upload_finishing_after_the_existence_check_wins
    append("first", at: 0, upload: "first")
    append("second", at: 0, upload: "second")
    other_store = InstantRecord::FileStore.new(@root)
    checked = ->(key) do
      refute other_store.exist?(key)
      other_store.finish(key, "second")
      false
    end

    stub_singleton(@store, :exist?, checked) do
      assert @store.finish("clip/one", "first")
    end

    assert_equal "second", File.binread(@store.path("clip/one"))
    assert_equal 0, @store.offset("clip/one", "first")
    assert_equal 0, @store.offset("clip/one", "second")
    assert @store.finish("clip/one", "first"), "finishing again is harmless"
  end

  def test_finishing_a_missing_upload_does_not_create_a_file
    assert_raises(Errno::ENOENT) { @store.finish("clip/one", "missing") }
    refute @store.exist?("clip/one")
  end

  def test_delete_takes_the_file_and_its_partials_and_nothing_else
    append("kept", at: 0, key: "clip/one-more")
    append("gone", at: 0)
    @store.finish("clip/one", "first")
    append("half", at: 0, upload: "second")

    @store.delete("clip/one")

    refute @store.exist?("clip/one")
    assert_equal 0, @store.offset("clip/one", "second")
    assert_equal 4, @store.offset("clip/one-more", "first"), "a record whose id starts the same keeps its upload"
  end

  def test_sweep_removes_only_the_uploads_that_were_given_up
    append("old", at: 0, upload: "old")
    append("new", at: 0, upload: "new")
    old = Dir.glob(File.join(@root, "clip", "*.old.part")).first
    File.utime(Time.now - 3 * 86_400, Time.now - 3 * 86_400, old)

    assert_equal 1, @store.sweep(before: Time.now - 86_400)
    assert_equal 0, @store.offset("clip/one", "old")
    assert_equal 3, @store.offset("clip/one", "new")
  end

  def test_sweep_continues_when_a_partial_disappears_after_the_scan
    append("gone", at: 0, upload: "gone")
    append("old", at: 0, upload: "old")
    append("new", at: 0, upload: "new")
    old = "#{@store.path('clip/one')}.old.part"
    gone = "#{@store.path('clip/one')}.gone.part"
    File.utime(Time.now - 3 * 86_400, Time.now - 3 * 86_400, old)
    original_mtime = File.method(:mtime)
    wrapped_mtime = lambda do |path|
      File.unlink(path) if path == gone
      original_mtime.call(path)
    end

    stub_singleton(File, :mtime, wrapped_mtime) do
      assert_equal 1, @store.sweep(before: Time.now - 86_400)
    end

    refute File.exist?(gone)
    refute File.exist?(old)
    assert_equal 3, @store.offset("clip/one", "new")
  end

  def test_an_upload_is_named_plainly
    assert_raises(ArgumentError) { append("x", at: 0, upload: "../../etc/passwd") }
    assert_raises(ArgumentError) { @store.offset("clip/one", "") }
  end

  def test_default_chunk_size_is_proxy_safe_and_configurable
    assert_equal 512 * 1024, InstantRecord::FileStore::DEFAULT_CHUNK_SIZE
    assert_operator InstantRecord::FileStore::DEFAULT_CHUNK_SIZE, :<, 1024 * 1024
    assert_equal InstantRecord::FileStore::DEFAULT_CHUNK_SIZE, @store.chunk_size

    small = InstantRecord::FileStore.new(@root, chunk_size: 4)
    assert_equal 4, small.chunk_size
    assert_equal 4, small.append("clip/small", "u1", StringIO.new("abcd"), at: 0, length: 4)

    too_big = assert_raises(InstantRecord::FileStore::ChunkTooLarge) do
      small.append("clip/big", "u1", StringIO.new("abcde"), at: 0, length: 5)
    end
    assert_equal 4, too_big.limit
    assert_equal 0, small.offset("clip/big", "u1"), "an oversized piece wrote nothing"

    assert_raises(ArgumentError) { InstantRecord::FileStore.new(@root, chunk_size: 0) }
    assert_raises(ArgumentError) { InstantRecord::FileStore.new(@root, chunk_size: -1) }
  end

  def test_store_uses_configured_file_chunk_size_unless_overridden
    previous = InstantRecord.config.file_chunk_size
    InstantRecord.config.file_chunk_size = 8

    assert_equal 8, @store.chunk_size
    assert_raises(InstantRecord::FileStore::ChunkTooLarge) do
      @store.append("clip/over", "u1", StringIO.new("012345678"), at: 0, length: 9)
    end

    explicit = InstantRecord::FileStore.new(@root, chunk_size: 16)
    assert_equal 16, explicit.chunk_size
  ensure
    InstantRecord.config.file_chunk_size = previous
  end

  def test_serve_returns_full_file_ranges_and_head
    append("hello world", at: 0)
    @store.finish("clip/one", "first")

    status, headers, body = serve("clip/one")
    assert_equal 200, status
    assert_equal "hello world", body
    assert_equal "11", headers["content-length"]
    assert_equal "application/octet-stream", headers["content-type"]

    range_status, range_headers, range_body = serve("clip/one", headers: { "HTTP_RANGE" => "bytes=6-10" })
    assert_equal 206, range_status
    assert_equal "world", range_body
    assert_equal "bytes 6-10/11", range_headers["content-range"]
    assert_equal "5", range_headers["content-length"]

    head_status, head_headers, head_body = serve("clip/one", method: "HEAD")
    assert_equal 200, head_status
    assert_equal "11", head_headers["content-length"]
    assert_empty head_body
  end

  def test_discard_removes_only_the_named_partial_and_is_idempotent
    append("aaaa", at: 0, upload: "first")
    append("bbbb", at: 0, upload: "second")

    @store.discard("clip/one", "first")
    assert_equal 0, @store.offset("clip/one", "first")
    assert_equal 4, @store.offset("clip/one", "second")

    # Discarding again or discarding an absent upload is a clean no-op.
    @store.discard("clip/one", "first")
    @store.discard("clip/one", "never-started")

    @store.finish("clip/one", "second")
    @store.discard("clip/one", "second")
    assert @store.exist?("clip/one")
    assert_equal "bbbb", File.binread(@store.path("clip/one"))

    assert_raises(ArgumentError) { @store.discard("clip/one", "../bad") }
  end

  def test_delete_is_idempotent_for_missing_keys
    @store.delete("clip/missing")
    append("data", at: 0)
    @store.finish("clip/one", "first")

    @store.delete("clip/one")
    @store.delete("clip/one")
    refute @store.exist?("clip/one")
  end

  def test_append_rejects_negative_or_non_integer_offset_and_length
    [-1, "0", 1.5, nil].each do |bad_at|
      assert_raises(ArgumentError, "expected at=#{bad_at.inspect} to fail") do
        @store.append("clip/one", "first", StringIO.new("abc"), at: bad_at, length: 3)
      end
    end

    [-1, "3", 2.5, nil].each do |bad_length|
      assert_raises(ArgumentError, "expected length=#{bad_length.inspect} to fail") do
        @store.append("clip/one", "first", StringIO.new("abc"), at: 0, length: bad_length)
      end
    end

    assert_equal 0, @store.offset("clip/one", "first"), "invalid arguments wrote nothing"
    assert_equal 0, @store.append("clip/one", "first", StringIO.new(""), at: 0, length: 0)
  end

  def test_keys_cannot_escape_the_store_root
    [
      "",
      nil,
      ".",
      "..",
      "../outside",
      "clip/../../outside",
      "clip/../other",
      "clip/./one",
      "/etc/passwd",
      File.join(@root, "clip/one"),
      "clip/one\0.bin",
      "clip/",
      "clip//one",
      "clip\\..\\outside"
    ].each do |bad_key|
      assert_raises(ArgumentError, "expected key=#{bad_key.inspect} to be rejected") { @store.path(bad_key) }
    end

    %w[clip/one mix/stem/one clip/~abcdef0123456789 ~top clip/a..b].each do |valid_key|
      resolved = @store.path(valid_key)
      assert resolved.start_with?("#{@root}/"), "expected #{valid_key.inspect} to resolve inside root"
    end
  end
end
