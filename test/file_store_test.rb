require "test_helper"
require "tmpdir"
require "stringio"

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
    File.define_singleton_method(:open) do |*args, &block|
      original_open.call(*args) do |file|
        file.define_singleton_method(:fsync) { raise failure }
        block.call(file)
      end
    end

    begin
      error = assert_raises(IOError) { append(" world", at: 5) }
      assert_same failure, error
    ensure
      File.define_singleton_method(:open, original_open)
    end

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

    @store.define_singleton_method(:exist?) { |key| checked.call(key) }
    begin
      assert @store.finish("clip/one", "first")
    ensure
      @store.singleton_class.remove_method(:exist?)
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
    File.define_singleton_method(:mtime) do |path|
      File.unlink(path) if path == gone
      original_mtime.call(path)
    end

    begin
      assert_equal 1, @store.sweep(before: Time.now - 86_400)
    ensure
      File.define_singleton_method(:mtime, original_mtime)
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
end
