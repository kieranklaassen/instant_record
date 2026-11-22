require "test_helper"
require "tmpdir"
# All of Rails's own module, not the part of it a controller loads when it
# first answers: InstantRecord asks `Rails.application` wherever Rails is.
require "rails"
require "action_controller"
require "rack/mock"
require File.expand_path("../app/controllers/instant_record/files_controller", __dir__)

# The files endpoints, asked as a browser asks them: each action is called as
# the Rack app the engine's routes hand a request to.
class FilesControllerTest < Minitest::Test
  PIECE = 4

  def ensure_clips_table!
    return if ActiveRecord::Base.connection.table_exists?(:clips)

    ActiveRecord::Migration.suppress_messages do
      ActiveRecord::Schema.define do
        create_table :clips, id: :string, force: true do |t|
          t.string :title
          t.string :owner
          t.string :content_type
          t.integer :byte_size
          t.integer :server_version, null: false, default: 0
          t.string :sync_state, null: false, default: "synced"
          t.timestamps
        end
      end
    end
  end

  def setup
    ensure_clips_table!
    reset_instant_record_tables!
    ActiveRecord::Base.connection.execute("DELETE FROM clips")
    @root = Dir.mktmpdir("instant-record-files")
    @previous_store = InstantRecord.config.file_store
    @previous_scope = InstantRecord.config.scope_from
    @previous_chunk_size = InstantRecord.config.file_chunk_size
    InstantRecord.config.file_store = InstantRecord::FileStore.new(@root)
    InstantRecord.config.file_chunk_size = nil
    # Who is asking is the request's `scope`, as a person.
    InstantRecord.config.scope_from = ->(request) { Person.new(request.params["scope"]) }

    @clip = Class.new(ActiveRecord::Base) do
      self.table_name = "clips"
      define_singleton_method(:name) { "Clip" }
      include InstantRecord::Syncable
      sync_file max_size: 64
      # A clip is its owner's, to read and to write. One with no owner is
      # everyone's to read.
      syncable_to { |who| where(owner: [nil, who&.id]) }
      writable_by { |who| who&.id ? where(owner: who.id) : none }
    end
    @plain = syncable_model("Item")
    InstantRecord.sync(@clip, @plain)
    on_server { @clip.create!(id: "take-1", title: "Take one", owner: "ada", byte_size: 10, content_type: "audio/wav") }
  end

  def teardown
    InstantRecord.sync
    InstantRecord.config.file_store = @previous_store
    InstantRecord.config.scope_from = @previous_scope
    InstantRecord.config.file_chunk_size = @previous_chunk_size
    FileUtils.remove_entry(@root) if @root && Dir.exist?(@root)
  end

  Reply = Struct.new(:status, :headers, :body) do
    def json = JSON.parse(body)
  end

  def ask(action, method, type: "Clip", id: "take-1", body: nil, content_type: "application/octet-stream", headers: {}, **query)
    env = Rack::MockRequest.env_for("/instant_record/files/#{id}?#{Rack::Utils.build_query(query)}",
      { method: method, input: body, "CONTENT_TYPE" => (content_type if body) }.compact.merge(headers))
    env["action_dispatch.request.path_parameters"] = { type: type, id: id }
    status, reply_headers, reply_body = InstantRecord::FilesController.action(action).call(env)
    bytes = +""
    reply_body.each { |part| bytes << part }
    reply_body.close if reply_body.respond_to?(:close)
    Reply.new(status, reply_headers, bytes)
  end

  def put(bytes, at:, size: 10, upload: "u1", scope: "ada", **options)
    ask(:update, "PUT", body: bytes, offset: at, size: size, upload: upload, scope: scope, **options)
  end

  def send_whole(bytes = "0123456789", **options)
    bytes.bytes.each_slice(PIECE).with_index.map do |piece, index|
      put(piece.pack("C*"), at: index * PIECE, size: bytes.bytesize, **options)
    end.last
  end

  def get(**options) = ask(:show, "GET", **options)

  def test_a_file_sent_in_pieces_is_read_back_whole
    first = put("0123", at: 0)
    assert_equal 200, first.status
    assert_equal({ "complete" => false, "offset" => 4, "chunk_size" => InstantRecord::Files::DEFAULT_CHUNK_SIZE }, first.json)
    assert_equal 404, get(scope: "ada").status, "half a file is no file"

    put("4567", at: 4)
    last = put("89", at: 8)
    assert_equal({ "complete" => true, "offset" => 10, "chunk_size" => InstantRecord::Files::DEFAULT_CHUNK_SIZE }, last.json)

    read = get(scope: "ada")
    assert_equal 200, read.status
    assert_equal "0123456789", read.body
    assert_equal "audio/wav", read.headers["content-type"]
    assert_equal "10", read.headers["content-length"]
    assert_equal InstantRecord::Files::DEFAULT_CHUNK_SIZE.to_s, read.headers["x-instant-record-chunk-size"]
  end

  def test_a_part_of_the_file_is_read_by_range
    send_whole

    part = get(scope: "ada", headers: { "HTTP_RANGE" => "bytes=4-7" })
    assert_equal 206, part.status
    assert_equal "4567", part.body
    assert_equal "bytes 4-7/10", part.headers["content-range"]

    rest = get(scope: "ada", headers: { "HTTP_RANGE" => "bytes=8-" })
    assert_equal "89", rest.body

    assert_equal 416, get(scope: "ada", headers: { "HTTP_RANGE" => "bytes=40-50" }).status
  end

  def test_head_says_the_file_is_here_and_sends_none_of_it
    assert_equal 404, ask(:show, "HEAD", scope: "ada").status
    send_whole

    head = ask(:show, "HEAD", scope: "ada")
    assert_equal 200, head.status
    assert_equal "10", head.headers["content-length"]
    assert_empty head.body
  end

  def test_an_upload_that_was_cut_off_goes_on_from_where_it_stood
    put("0123", at: 0)

    standing = ask(:progress, "GET", upload: "u1", scope: "ada")
    assert_equal({ "complete" => false, "offset" => 4, "chunk_size" => InstantRecord::Files::DEFAULT_CHUNK_SIZE }, standing.json)

    again = put("0123", at: 0)
    assert_equal 409, again.status
    assert_equal 4, again.json["offset"]
    assert_equal InstantRecord::Files::DEFAULT_CHUNK_SIZE, again.json["chunk_size"]

    put("4567", at: 4)
    put("89", at: 8)
    assert_equal({ "complete" => true, "offset" => 10, "chunk_size" => InstantRecord::Files::DEFAULT_CHUNK_SIZE }, ask(:progress, "GET", upload: "u1", scope: "ada").json)
  end

  def test_a_file_that_is_here_is_never_written_again
    send_whole
    again = put("XXXX", at: 0, upload: "u2")

    assert_equal 200, again.status
    assert_equal({ "complete" => true, "offset" => 10, "chunk_size" => InstantRecord::Files::DEFAULT_CHUNK_SIZE }, again.json)
    assert_equal "0123456789", get(scope: "ada").body
  end

  def test_two_uploads_of_one_record_each_keep_their_own_pieces
    put("0123", at: 0, upload: "u1")
    other = put("abcd", at: 0, upload: "u2")

    assert_equal 4, other.json["offset"]
    assert_equal 4, ask(:progress, "GET", upload: "u1", scope: "ada").json["offset"]
  end

  def test_the_file_may_be_read_by_whoever_may_be_sent_the_record
    send_whole
    on_server { @clip.create!(id: "shared", title: "For everyone", byte_size: 10) }
    key = InstantRecord::Files.key(@clip, "shared")
    InstantRecord::Files.store.append(key, "seed", StringIO.new("everybody!"), at: 0, length: 10)
    InstantRecord::Files.store.finish(key, "seed")

    assert_equal 200, get(scope: "ada").status
    assert_equal 404, get(scope: "ben").status, "another person's file answers as a missing one does"
    assert_equal 404, get.status, "and so it does to nobody at all"
    assert_equal "everybody!", get(id: "shared", scope: "ben").body
    assert_equal "everybody!", get(id: "shared").body
  end

  def test_the_file_may_be_sent_by_whoever_may_write_the_record
    on_server { @clip.create!(id: "shared", title: "For everyone", byte_size: 10) }

    assert_equal 404, put("0123", at: 0, scope: "ben").status
    assert_equal 404, put("0123", at: 0, scope: nil).status
    assert_equal 404, put("0123", at: 0, id: "shared", scope: "ben").status, "readable is not writable"
    assert_equal 404, ask(:progress, "GET", upload: "u1", scope: "ben").status
    assert_empty Dir.children(@root), "nothing a stranger sent was kept"
  end

  def test_a_file_sent_before_its_record_is_missing_until_the_record_arrives
    assert_equal 404, put("0123", at: 0, id: "take-2").status

    on_server { @clip.create!(id: "take-2", owner: "ada", byte_size: 10) }
    assert_equal 200, put("0123", at: 0, id: "take-2").status
  end

  def test_a_file_is_the_size_its_record_gives_and_no_larger_than_the_model_takes
    wrong = put("0123", at: 0, size: 12)
    assert_equal 422, wrong.status
    assert_equal "not the size the record gives", wrong.json["error"]

    on_server { @clip.create!(id: "long", owner: "ada", byte_size: 65) }
    assert_equal 413, put("0123", at: 0, size: 65, id: "long").status

    past = put("0123456789ab", at: 0)
    assert_equal 422, past.status
    assert_equal "past the end of the file", past.json["error"]
    assert_empty Dir.children(@root)
  end

  def test_a_record_without_a_size_column_takes_the_size_it_is_sent
    @plain.sync_file
    on_server { @plain.create!(id: "loose", title: "No columns") }

    assert_equal true, send_whole("abcdef", type: "Item", id: "loose", scope: nil).json["complete"]
    read = get(type: "Item", id: "loose")
    assert_equal "abcdef", read.body
    assert_equal "application/octet-stream", read.headers["content-type"]
  end

  def test_only_a_model_that_carries_files_answers
    on_server { @plain.create!(id: "plain", title: "No file") }

    assert_equal 404, get(type: "Item", id: "plain").status
    assert_equal 404, put("0123", at: 0, type: "Item", id: "plain").status
    assert_equal 404, get(type: "Nothing").status
    assert_equal 404, get(type: "Kernel").status
  end

  def test_a_piece_is_bytes_with_a_length_and_an_upload_of_its_own
    assert_equal 415, put("0123", at: 0, content_type: "application/x-www-form-urlencoded").status
    assert_equal 400, put("0123", at: 0, upload: "../../x").status
    assert_equal 400, put("0123", at: 0, upload: nil).status
    assert_equal 411, ask(:update, "PUT", offset: 0, size: 10, upload: "u1", scope: "ada",
      headers: { "CONTENT_TYPE" => "application/octet-stream" }).status
  end

  def test_what_a_file_is_said_to_be_cannot_run_in_the_apps_origin
    on_server { @clip.create!(id: "page", owner: "ada", byte_size: 10, content_type: "text/html") }
    send_whole("<script>1;", id: "page")

    read = get(id: "page", scope: "ada")
    assert_equal "attachment", read.headers["content-disposition"]
    assert_equal "nosniff", read.headers["x-content-type-options"]
    assert_match "sandbox", read.headers["content-security-policy"]
  end

  def test_another_origin_may_ask
    preflight = ask(:preflight, "OPTIONS")
    assert_equal 204, preflight.status
    assert_equal "*", preflight.headers["access-control-allow-origin"]
    assert_includes preflight.headers["access-control-allow-methods"], "PUT"
    assert_includes preflight.headers["access-control-allow-headers"], "range"
  end

  def test_a_destroyed_record_takes_its_file_and_its_address_with_it
    send_whole
    on_server { @clip.find("take-1").destroy! }

    assert_equal 404, get(scope: "ada").status
    assert_empty Dir.glob(File.join(@root, "**", "*")).select { |path| File.file?(path) }
  end

  def test_a_piece_larger_than_configured_chunk_size_is_refused_with_the_limit
    InstantRecord.config.file_chunk_size = 4

    standing = ask(:progress, "GET", upload: "u1", scope: "ada")
    assert_equal({ "complete" => false, "offset" => 0, "chunk_size" => 4 }, standing.json)

    too_big = put("01234", at: 0)
    assert_equal 413, too_big.status
    assert_equal({ "error" => "piece larger than this server takes", "chunk_size" => 4 }, too_big.json)
    assert_empty Dir.children(@root), "an oversized piece left nothing on disk"

    assert_equal 200, put("0123", at: 0).status
    assert_equal 200, put("4567", at: 4).status
    assert_equal 200, put("89", at: 8).status

    head = ask(:show, "HEAD", scope: "ada")
    assert_equal "4", head.headers["x-instant-record-chunk-size"]
    assert_includes head.headers["access-control-expose-headers"], "x-instant-record-chunk-size"
  end
end
