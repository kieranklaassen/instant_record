require "test_helper"
require "tmpdir"
require "stringio"

class FilesTest < Minitest::Test
  def setup
    reset_instant_record_tables!
    @root = Dir.mktmpdir("instant-record-files")
    @previous = InstantRecord.config.file_store
    InstantRecord.config.file_store = InstantRecord::FileStore.new(@root)
    # MutationApplier finds a model by its name, so these are the allowlist.
    @clip = syncable_model("Clip") { sync_file max_size: 1024 }
    @plain = syncable_model("Item")
    InstantRecord.sync(@clip, @plain)
  end

  def teardown
    InstantRecord.sync
    InstantRecord.config.file_store = @previous
    FileUtils.remove_entry(@root)
  end

  def store = InstantRecord::Files.store

  def keep(model, id, bytes = "bytes")
    key = InstantRecord::Files.key(model, id)
    store.append(key, "up", StringIO.new(bytes), at: 0, length: bytes.bytesize)
    store.finish(key, "up")
    key
  end

  def test_a_model_carries_files_only_when_it_says_so
    assert InstantRecord::Files.carried_by?(@clip)
    refute InstantRecord::Files.carried_by?(@plain)
    assert_equal @clip, InstantRecord::Files.model("Clip")
    assert_nil InstantRecord::Files.model("Item")
    assert_nil InstantRecord::Files.model("Nothing")
  end

  def test_the_most_bytes_is_the_models_or_the_configured_one
    assert_equal 1024, InstantRecord::Files.max_size(@clip)
    assert_equal InstantRecord::Files::MAX_SIZE, InstantRecord::Files.max_size(syncable_model("Other") { sync_file })
    InstantRecord.config.max_file_size = 4096
    assert_equal 4096, InstantRecord::Files.max_size(syncable_model("Another") { sync_file })
  ensure
    InstantRecord.config.max_file_size = nil
  end

  def test_chunk_size_defaults_safely_and_respects_model_config_and_store_limits
    assert_equal 512 * 1024, InstantRecord::Files.chunk_size(@clip)

    custom_model = syncable_model("SmallChunk") { sync_file chunk_size: 65_536 }
    large_model = syncable_model("LargeChunk") { sync_file chunk_size: 2 * 1024 * 1024 }
    assert_equal 65_536, InstantRecord::Files.chunk_size(custom_model)
    assert_equal 512 * 1024, InstantRecord::Files.chunk_size(large_model), "a model cannot exceed the server chunk ceiling"

    InstantRecord.config.file_chunk_size = 262_144
    assert_equal 262_144, InstantRecord::Files.chunk_size(@clip)
    assert_equal 65_536, InstantRecord::Files.chunk_size(custom_model)
    assert_equal 262_144, InstantRecord::Files.chunk_size(large_model)

    InstantRecord.config.file_chunk_size = 1024 * 1024
    assert_equal 1024 * 1024, InstantRecord::Files.chunk_size(large_model)

    InstantRecord.config.file_store = InstantRecord::FileStore.new(@root, chunk_size: 32_768)
    assert_equal 32_768, InstantRecord::Files.chunk_size(@clip)
    assert_equal 32_768, InstantRecord::Files.chunk_size(custom_model)
  ensure
    InstantRecord.config.file_chunk_size = nil
  end

  # configuration.rb and syncable.rb are compiled for the browser, where an
  # integer has 32 bits: a number past that raised a RangeError in the first
  # sync of a compiled app and no bootstrap was ever applied.
  def test_what_the_browser_compiles_holds_no_number_past_32_bits
    assert_nil InstantRecord::Configuration.new.max_file_size
    assert_nil InstantRecord::Configuration.new.file_chunk_size
    %w[configuration.rb syncable.rb].each do |file|
      source = File.read(File.expand_path("../lib/instant_record/#{file}", __dir__), encoding: "UTF-8")
      refute_match(/\d\s*\*\s*\d|\*\*|\d{10,}/, source.gsub(/^\s*#.*$/, ""), "#{file} computes a number the browser may not hold")
    end
  end

  def test_a_key_is_a_path_inside_the_models_folder
    assert_equal "clip/3f2a-01", InstantRecord::Files.key(@clip, "3f2a-01")

    odd = InstantRecord::Files.key(@clip, "../../etc/passwd")
    assert_match %r{\Aclip/~\h{64}\z}, odd
    assert_equal odd, InstantRecord::Files.key(@clip, "../../etc/passwd")
    refute_equal odd, InstantRecord::Files.key(@clip, "..%2F..%2Fetc%2Fpasswd")
  end

  def test_a_namespaced_model_keeps_its_files_in_a_folder_of_its_own
    stem = syncable_model("Mix::Stem") { sync_file }
    assert_equal "mix/stem/one", InstantRecord::Files.key(stem, "one")
  end

  def test_a_record_destroyed_on_the_server_takes_its_file
    record = on_server { @clip.create!(title: "take one") }
    key = keep(@clip, record.id)

    on_server { record.destroy! }

    refute store.exist?(key)
  end

  def test_a_record_destroyed_by_a_client_takes_its_file
    record = on_server { @clip.create!(title: "take one") }
    key = keep(@clip, record.id)
    other = keep(@clip, "another")

    result = on_server do
      InstantRecord::MutationApplier.apply(id: "m1", record_type: "Clip", record_id: record.id, operation: "destroy")
    end

    assert_equal "applied", result[:status]
    refute store.exist?(key)
    assert store.exist?(other), "only the destroyed record's file goes"
  end

  def test_an_update_leaves_the_file_alone
    record = on_server { @clip.create!(title: "take one") }
    key = keep(@clip, record.id)

    on_server { record.update!(title: "take two") }

    assert store.exist?(key)
  end

  def test_a_model_without_files_is_destroyed_as_before
    record = on_server { @plain.create!(title: "plain") }
    on_server { record.destroy! }

    assert_empty Dir.children(@root)
  end
end
