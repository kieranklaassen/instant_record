require "test_helper"
require "instant_record/mcp"
require "fileutils"
require "json"
require "tmpdir"

class McpHostProcessTest < ActiveSupport::TestCase
  test "speaks the native host.c framing protocol including UTF-8 byte counts, exchange callbacks, boot, and open" do
    Dir.mktmpdir do |dir|
      fake_host = write_fake_host(dir)
      db_path = File.join(dir, "replica.sqlite3")
      other_db = File.join(dir, "other.sqlite3")

      exchanges = []
      exchange = lambda do |req|
        exchanges << req
        "200\n{\"ok\":true,\"note\":\"café ☕\"}"
      end

      host = InstantRecord::Mcp::HostProcess.new(binary: fake_host, database: db_path, exchange: exchange)
      assert host.alive?
      assert_equal db_path, host.database_path

      # Multi-byte UTF-8 input and output verify byte-length framing.
      res = host.call("echo", "héllo 🌍")
      assert_equal "echo:héllo 🌍", res.out
      assert_equal "records_changed\nNote:1", res.notice

      # Sync triggers an inline `exchange` round-trip.
      sync_res = host.call("sync", "http://example.test/instant_record")
      assert_equal 1, exchanges.size
      assert_equal "GET http://example.test/instant_record/bootstrap\n", exchanges.first
      assert_includes sync_res.out, "café ☕"

      # Open switches the active database path.
      host.open(other_db)
      assert_equal other_db, host.database_path
      assert_equal other_db, host.call("pwd_db", "").out

      # Application errors surface as HostError without killing the process.
      err = assert_raises(InstantRecord::Mcp::HostError) { host.call("fail", "bad input") }
      assert_equal "Validation failed: bad input", err.message
      assert_equal "echo:still alive", host.call("echo", "still alive").out

      host.close
      refute host.alive?
    end
  end

  test "an error message cut inside a character is still valid UTF-8" do
    Dir.mktmpdir do |dir|
      host = InstantRecord::Mcp::HostProcess.new(binary: write_fake_host(dir), database: File.join(dir, "replica.sqlite3"))
      error = assert_raises(InstantRecord::Mcp::HostError) { host.call("fail", "caf\xC3") }
      assert_equal "Validation failed: caf\u{FFFD}", error.message
    ensure
      host&.close
    end
  end

  test "an exchange that raises is reported once the host has its answer, and the host is ready again" do
    Dir.mktmpdir do |dir|
      raised = nil
      host = InstantRecord::Mcp::HostProcess.new(binary: write_fake_host(dir), database: File.join(dir, "replica.sqlite3"), exchange: ->(*) { raise raised })
      [ArgumentError.new("bad"), EncodingError.new("bad"), TypeError.new("bad"), IOError.new("bad"), URI::InvalidComponentError.new("bad")].each do |error|
        raised = error
        shown = assert_raises(InstantRecord::Mcp::ExchangeError) { host.call("sync", "http://example.test") }
        assert_equal "Sync request failed: #{error.class}: bad", shown.message
        assert_equal "echo:ready", host.call("echo", "ready").out
      end
    ensure
      host&.close
    end
  end

  test "supports deferred boot with database '-'" do
    Dir.mktmpdir do |dir|
      fake_host = write_fake_host(dir)
      db_path = File.join(dir, "late.sqlite3")

      host = InstantRecord::Mcp::HostProcess.new(binary: fake_host, database: nil, chdir: dir)
      assert_nil host.database_path

      host.boot(db_path)
      assert_equal db_path, host.database_path
      assert_equal db_path, host.call("pwd_db", "").out
      host.close
    end
  end

  test "raises ArgumentError when binary is missing or not executable and HostCrashedError on unexpected exit" do
    Dir.mktmpdir do |dir|
      assert_raises(ArgumentError) do
        InstantRecord::Mcp::HostProcess.new(binary: File.join(dir, "missing"), database: File.join(dir, "a.sqlite3"))
      end

      crasher = File.join(dir, "crash_host")
      File.write(crasher, <<~RUBY)
        #!#{RbConfig.ruby}
        $stdout.binmode
        $stdout.write("ok 0 0\\n")
        $stdout.flush
        $stderr.puts("boom on stderr")
        exit 1
      RUBY
      File.chmod(0o755, crasher)

      host = InstantRecord::Mcp::HostProcess.new(binary: crasher, database: File.join(dir, "a.sqlite3"))
      err = assert_raises(InstantRecord::Mcp::HostCrashedError) { host.call("cursor", "") }
      assert_match(/Native host/, err.message)
      host.close
    end
  end

  private

  def write_fake_host(dir)
    path = File.join(dir, "fake_host")
    File.write(path, "#!#{RbConfig.ruby}\n" + <<~'RUBY')
      $stdin.binmode
      $stdout.binmode

      def read_exact(len)
        return "".b if len <= 0
        buf = "".b
        while buf.bytesize < len
          chunk = $stdin.read(len - buf.bytesize)
          exit 2 if chunk.nil? || chunk.empty?
          buf << chunk
        end
        buf
      end

      def send_ok(out = "", notice = "")
        o = out.b
        n = notice.b
        $stdout.write("ok #{o.bytesize} #{n.bytesize}\n")
        $stdout.write(o)
        $stdout.write(n)
        $stdout.flush
      end

      def send_error(msg)
        m = msg.b
        $stdout.write("error #{m.bytesize}\n")
        $stdout.write(m)
        $stdout.flush
      end

      db = ARGV[0] == "-" ? nil : ARGV[0]
      send_ok

      while (line = $stdin.gets)
        parts = line.strip.split
        verb = parts[0]
        case verb
        when "call"
          entry = parts[1]
          size = parts[2].to_i
          input = read_exact(size).force_encoding(Encoding::UTF_8)
          case entry
          when "echo"
            send_ok("echo:#{input}", "records_changed\nNote:1")
          when "pwd_db"
            send_ok(db.to_s)
          when "fail"
            send_error("Validation failed: #{input}")
          when "sync"
            req = "GET #{input}/bootstrap\n".b
            $stdout.write("exchange #{req.bytesize}\n")
            $stdout.write(req)
            $stdout.flush
            resp_len = $stdin.gets.to_i
            resp = read_exact(resp_len).force_encoding(Encoding::UTF_8)
            send_ok("changed resp=#{resp}")
          else
            send_error("No entry named #{entry}")
          end
        when "boot", "open"
          size = parts[1].to_i
          db = read_exact(size).force_encoding(Encoding::UTF_8)
          send_ok
        else
          exit 2
        end
      end
    RUBY
    File.chmod(0o755, path)
    path
  end
end
