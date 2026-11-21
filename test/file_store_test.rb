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

  def test_an_upload_is_named_plainly
    assert_raises(ArgumentError) { append("x", at: 0, upload: "../../etc/passwd") }
    assert_raises(ArgumentError) { @store.offset("clip/one", "") }
  end
end
