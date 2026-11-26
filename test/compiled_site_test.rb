require_relative "test_helper"
require_relative "../lib/instant_record/compiled_site"
require "rack/mock"
require "tmpdir"

class CompiledSiteTest < Minitest::Test
  def setup
    # Manifests are read in the default encoding, which a shell without LANG sets to ASCII.
    @encoding = Encoding.default_external
    use_encoding(Encoding::UTF_8)
    @dir = Dir.mktmpdir
    @root = File.join(@dir, "current")
  end

  def teardown
    FileUtils.remove_entry(@dir)
    use_encoding(@encoding)
  end

  def release(name, manifest)
    path = File.join(@dir, name)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "index.html"), "local")
    File.binwrite(File.join(path, "instant_record.manifest.json"), manifest) if manifest
    path
  end

  def point_at(path)
    temp = File.join(@dir, "next")
    File.symlink(path, temp)
    File.rename(temp, @root)
  end

  def serve(manifest)
    point_at(release("one", manifest))
    site
  end

  # A site whose clock the tests move, instead of waiting for a manifest to settle.
  class Site < InstantRecord::CompiledSite
    attr_accessor :ahead, :clock, :during_read

    private

    def now = (clock || super) + ahead.to_i

    def parse_routes(json)
      hook, @during_read = @during_read, nil if @during_read
      super.tap { hook&.call }
    end
  end

  def site
    @site ||= Site.new(->(_env) { [200, {}, ["Rails"]] },
      host: "browser.test", root: @root, sync_path: "/instant_record")
  end

  def get(path, app = site)
    env = Rack::MockRequest.env_for("https://browser.test/", "HTTP_ACCEPT" => "text/html")
    env["PATH_INFO"] = path
    _status, _headers, body = app.call(env)
    text = +""
    body.each { |part| text << part }
    body.close if body.respond_to?(:close)
    text
  end

  def island(*paths)
    JSON.generate(mode: "island", local_routes: paths.map { |path| { method: "GET", path: path } })
  end

  # Once with the manifest read on each request, then with it kept.
  def fresh_and_kept(first_path = "/")
    yield
    site.ahead = 3
    get(first_path)
    yield
  end

  def use_encoding(encoding)
    verbose, $VERBOSE = $VERBOSE, nil
    Encoding.default_external = encoding
  ensure
    $VERBOSE = verbose
  end

  # Waits until a change to the file shows in its stat, whatever the file system's tick.
  def next_tick(file)
    before = File.stat(file)
    probe = File.join(@dir, "probe")
    deadline = monotonic + 6
    while monotonic < deadline
      File.write(probe, "")
      File.utime(Time.now, Time.now, probe)
      return if File.stat(probe).ctime > before.ctime
      sleep 0.002
    end
    flunk "no later change time than #{before.ctime.inspect} within 6 seconds"
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def test_routes_match_as_written
    serve(island("/", "/items", "/items/:id", "/docs/*rest", "/a.b", "/v/:id.json", "bare//path/", "/f:x-y"))
    answers = {
      "/" => "local", "//" => "local", "/items" => "local", "/items/" => "local", "//items" => "local",
      "/items//" => "local", "/items/4" => "local", "/items/4/5" => "Rails", "/docs" => "Rails",
      "/docs/a/b" => "local", "/a.b" => "local", "/axb" => "Rails", "/v/9.json" => "local",
      "/bare/path" => "local", "/fanything-y" => "local", "/f/a-y" => "Rails",
      "/ITEMS" => "Rails", "/items\n" => "Rails", "/items/a\nb" => "local", "/docs/a\nb" => "Rails"
    }
    fresh_and_kept { answers.each { |path, body| assert_equal body, get(path), path.inspect } }
  end

  def test_only_get_routes_with_a_path_count
    serve(JSON.generate(mode: "island", local_routes: [{ method: "post", path: "/a" }, { method: "get", path: "/b" },
      { method: "GET", path: nil }, { path: "/c" }]))
    fresh_and_kept { assert_equal %w[Rails local Rails], ["/a", "/b", "/c"].map { |path| get(path) } }
  end

  def test_manifests_that_answer_everything_locally
    [nil, "", "{", "\xFF", "{}", '"mode"', '{"mode":"full"}', '{"mode":"island"}',
      '{"mode":"island","local_routes":[]}', '{"mode":"island","local_routes":["x"]}',
      '{"mode":"island","local_routes":[{"method":"POST","path":"/a"}]}'].each_with_index do |manifest, index|
      point_at(release("local#{index}", manifest))
      assert_equal "local", get("/anything"), manifest.inspect
      assert_equal "local", get("/anything"), manifest.inspect
    end
  end

  def test_json_of_another_shape_raises_every_time
    { "null" => NoMethodError, "true" => NoMethodError, "1.5" => NoMethodError, "5" => TypeError, "[]" => TypeError,
      '{"mode":"island","local_routes":5}' => TypeError, '{"mode":"island","local_routes":{"a":1}}' => TypeError,
      '{"mode":"island","local_routes":[null]}' => NoMethodError }.each_with_index do |(manifest, error), index|
      point_at(release("shape#{index}", manifest))
      2.times { assert_raises(error, manifest) { get("/anything") } }
    end
  end

  def test_a_binary_path_against_a_non_ascii_route_raises_only_when_that_route_is_reached
    serve(island("/first/:id", "/é", "/last"))
    fresh_and_kept("/last") do
      assert_equal "local", get("/first/\xC3\xA9".b)
      assert_equal "local", get("/last")
      assert_raises(Encoding::CompatibilityError) { get("/caf\xC3\xA9".b) }
    end
  end

  def test_a_release_swap_is_seen_at_once_and_back_again
    one = release("one", island("/a"))
    two = release("two", island("/b"))
    point_at(one)
    site.ahead = 3
    3.times do
      point_at(one)
      2.times { assert_equal %w[local Rails], [get("/a"), get("/b")] }
      point_at(two)
      2.times { assert_equal %w[Rails local], [get("/a"), get("/b")] }
    end
  end

  def test_rewrites_in_place_are_seen_at_once
    serve(island("/a"))
    file = File.join(@root, "instant_record.manifest.json")
    # Same size, and as fast as the file system can be written.
    50.times do |index|
      name = index.even? ? "b" : "a"
      File.write(file, island("/#{name}"))
      assert_equal "local", get("/#{name}")
      assert_equal "Rails", get(index.even? ? "/a" : "/b")
    end

    # Same size and the same modification time, long after the file was read.
    time = File.mtime(file)
    site.ahead = 3
    next_tick(file)
    2.times { assert_equal %w[local Rails], [get("/a"), get("/b")] }
    File.write(file, island("/b"))
    File.utime(time, time, file)
    assert_equal %w[Rails local], [get("/a"), get("/b")]
  end

  def test_a_kept_manifest_follows_removal_damage_and_permissions
    serve(island("/a"))
    file = File.join(@root, "instant_record.manifest.json")
    site.ahead = 3
    2.times { assert_equal "Rails", get("/b") }

    next_tick(file)
    unless Process.uid.zero?
      File.chmod(0, file)
      2.times { assert_equal "local", get("/b") }
      File.chmod(0o644, file)
      assert_equal "Rails", get("/b")
    end
    File.write(file, "{")
    assert_equal "local", get("/b")
    File.write(file, island("/a"))
    assert_equal "Rails", get("/b")
    File.delete(file)
    assert_equal "local", get("/b")
    Dir.mkdir(file)
    assert_equal "local", get("/b")
    Dir.rmdir(file)
    File.write(file, island("/a"))
    assert_equal "Rails", get("/b")
    File.delete(@root)
    2.times { assert_equal "Not found: /index.html\n", get("/b").sub(/File not found/, "Not found") }
  end

  def test_a_frozen_instance_answers
    serve(island("/a"))
    site.ahead = 3
    frozen = site.freeze
    2.times { assert_equal %w[local Rails], [get("/a", frozen), get("/b", frozen)] }
  end

  def test_threads_and_forks_see_a_swap
    one = release("one", island("/a"))
    two = release("two", island("/b"))
    point_at(one)
    site.ahead = 3
    assert_equal "local", get("/a")
    both = %w[local Rails]
    wrong = Queue.new
    stop = false
    threads = 6.times.map do
      Thread.new do
        until stop
          wrong << "both releases have /none" unless get("/none") == "Rails"
          wrong << "answer" unless both.include?(get("/a"))
        end
      end
    end
    40.times { |index| point_at(index.even? ? two : one) }
    point_at(two)
    assert_equal %w[Rails local], [get("/a"), get("/b")]
    stop = true
    threads.each(&:join)
    assert_empty wrong
    return unless Process.respond_to?(:fork)

    point_at(one)
    assert_equal "local", get("/a")
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      point_at(two)
      writer.write([get("/a"), get("/b")].join(","))
      writer.close
      exit!(0)
    end
    writer.close
    assert_equal "Rails,local", reader.read
    Process.wait(pid)
    assert_equal "local", get("/b")
  end

  def test_a_settled_manifest_is_parsed_once_and_a_fresh_one_each_time
    serve(island("/a"))
    file = File.join(@root, "instant_record.manifest.json")
    # Dated ahead, it stays fresh however slowly this test runs.
    ahead = Time.now + 3600
    File.utime(ahead, ahead, file)
    assert_equal 3, parses { 3.times { get("/a") } }
    File.write(file, island("/b"))
    site.ahead = 3
    assert_equal 1, parses { 3.times { get("/b") } }
  end

  def test_a_route_that_cannot_be_built_raises_only_when_it_is_reached
    serve(island("/a", "/x").sub("/x", "/\xFF"))
    fresh_and_kept("/a") do
      assert_equal "local", get("/a")
      assert_raises(ArgumentError) { get("/b") }
    end
  end

  def test_a_manifest_settles_two_seconds_after_its_last_change_of_either_kind
    serve(island("/a"))
    file = File.join(@root, "instant_record.manifest.json")
    changed = File.stat(file).then { |stat| [stat.mtime, stat.ctime].max }
    site.clock = changed + 1.9
    assert_equal 2, parses { 2.times { get("/a") } }
    site.clock = changed + 2.1
    assert_equal 1, parses { 2.times { get("/a") } }

    # An old change time does not settle a file that is dated ahead.
    ahead = changed + 3600
    File.utime(ahead, ahead, file)
    site.clock = changed + 60
    assert_equal 2, parses { 2.times { get("/a") } }

    # An old modification time does not settle a file that just changed.
    past = changed - 3600
    next_tick(file)
    File.utime(past, past, file)
    site.clock = File.stat(file).ctime + 1
    assert_equal 2, parses { 2.times { get("/a") } }
  end

  def test_a_write_during_the_read_is_seen_by_the_next_request
    serve(island("/a"))
    file = File.join(@root, "instant_record.manifest.json")
    site.ahead = 3
    site.during_read = lambda do
      next_tick(file)
      File.write(file, island("/b"))
    end
    assert_equal "local", get("/a")
    assert_equal %w[Rails local], [get("/a"), get("/b")]
  end

  private

  def parses
    count = 0
    trace = TracePoint.new(:call, :c_call) { |point| count += 1 if point.method_id == :parse && point.self.equal?(JSON) }
    trace.enable { yield }
    count
  end
end
