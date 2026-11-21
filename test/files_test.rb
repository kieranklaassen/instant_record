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
    assert_equal InstantRecord.config.max_file_size, InstantRecord::Files.max_size(syncable_model("Other") { sync_file })
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
