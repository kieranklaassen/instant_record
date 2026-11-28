require "test_helper"
require "instant_record/mcp"
require "fileutils"
require "json"
require "timeout"
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

      Timeout.timeout(5) { sleep 0.01 while host.alive? }
      [-> { host.call("cursor", "") }, -> { host.open(File.join(dir, "b.sqlite3")) }, -> { host.boot(File.join(dir, "b.sqlite3")) }].each do |call|
        err = assert_raises(InstantRecord::Mcp::HostCrashedError, &call)
        assert_equal "Native host pipe error: Broken pipe", err.message
      end
      host.close
    end
  end

  test "close escalates TERM to KILL and reaps a hung host ignoring SIGTERM" do
    Dir.mktmpdir do |dir|
      pid_file = File.join(dir, "hung.pid")
      hung = File.join(dir, "hung_host")
      File.write(hung, <<~RUBY)
        #!#{RbConfig.ruby}
        Signal.trap("TERM", "IGNORE")
        File.write(#{pid_file.inspect}, Process.pid.to_s)
        $stdout.binmode
        $stdout.write("ok 0 0\\n")
        $stdout.flush
        sleep 60
      RUBY
      File.chmod(0o755, hung)

      host = InstantRecord::Mcp::HostProcess.new(binary: hung, database: File.join(dir, "a.sqlite3"))
      pid = File.read(pid_file).to_i
      assert_equal 1, Process.kill(0, pid)

      Timeout.timeout(10) { host.close }
      assert_equal false, host.alive?
      assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
    ensure
      if defined?(pid) && pid && pid > 0
        Process.kill("KILL", pid) rescue Errno::ESRCH
      end
    end
  end

  test "spawn_process! propagates Open3.popen3 failure instead of NoMethodError from close" do
    Dir.mktmpdir do |dir|
      unspawnable = File.join(dir, "bad_interpreter_host")
      File.write(unspawnable, "#!#{File.join(dir, "missing_interpreter")}\n")
      File.chmod(0o755, unspawnable)

      err = assert_raises(Errno::ENOENT) do
        InstantRecord::Mcp::HostProcess.new(binary: unspawnable, database: File.join(dir, "a.sqlite3"))
      end
      refute_kind_of NoMethodError, err
    end
  end

  test "boot and open create parent directories, update database_path, and leave it unchanged on error" do
    Dir.mktmpdir do |dir|
      host = InstantRecord::Mcp::HostProcess.new(binary: write_fake_host(dir), database: nil, chdir: dir)
      boot_db = File.join(dir, "nested", "boot", "replica.sqlite3")
      open_db = File.join(dir, "nested", "open", "replica.sqlite3")
      failing_db = File.join(dir, "nested", "fail", "fail.sqlite3")

      refute Dir.exist?(File.dirname(boot_db))
      boot_result = host.boot(boot_db)
      assert_kind_of InstantRecord::Mcp::HostProcess::Result, boot_result
      assert Dir.exist?(File.dirname(boot_db))
      assert_equal boot_db, host.database_path
      assert_equal boot_db, host.call("pwd_db", "").out

      refute Dir.exist?(File.dirname(open_db))
      open_result = host.open(open_db)
      assert_kind_of InstantRecord::Mcp::HostProcess::Result, open_result
      assert Dir.exist?(File.dirname(open_db))
      assert_equal open_db, host.database_path
      assert_equal open_db, host.call("pwd_db", "").out

      err = assert_raises(InstantRecord::Mcp::HostError) { host.open(failing_db) }
      assert_equal "Cannot open database", err.message
      assert_equal open_db, host.database_path
    ensure
      host&.close
    end
  end

  test "raises HostCrashedError on malformed headers, negative lengths, unexpected responses, and mid-frame EOF" do
    cases = [
      ["ok 1\n", /\AMalformed ok frame from native host:/],
      ["exchange\n", /\AMalformed exchange frame from native host:/],
      ["error\n", /\AMalformed error frame from native host:/],
      ["ok nope 0\n", /\AInvalid frame header from native host:/],
      ["ok -1 0\n", /\AInvalid frame header from native host: negative frame length/],
      ["ok 0 -2\n", /\AInvalid frame header from native host: negative frame length/],
      ["exchange -3\n", /\AInvalid frame header from native host: negative frame length/],
      ["error -4\n", /\AInvalid frame header from native host: negative frame length/],
      ["unknown 0\n", /\AUnexpected response from native host:/],
      ["ok 10 0\nabc", /\ANative host closed stream mid-frame \(expected 10 bytes, got 3\)\z/]
    ]

    Dir.mktmpdir do |dir|
      cases.each do |raw_reply, expected_pattern|
        host = InstantRecord::Mcp::HostProcess.new(binary: write_raw_reply_host(dir, raw_reply), database: File.join(dir, "a.sqlite3"))
        err = assert_raises(InstantRecord::Mcp::HostCrashedError) { host.call("probe", "") }
        assert_match expected_pattern, err.message, "Unexpected message for #{raw_reply.inspect}"
      ensure
        host&.close
      end
    end
  end

  test "multi-exchange failure completes every exchange handshake and reports the first error" do
    Dir.mktmpdir do |dir|
      attempts = 0
      exchange = lambda do |_req|
        attempts += 1
        raise RuntimeError, "attempt #{attempts}"
      end

      host = InstantRecord::Mcp::HostProcess.new(
        binary: write_fake_host(dir),
        database: File.join(dir, "replica.sqlite3"),
        exchange: exchange
      )
      err = assert_raises(InstantRecord::Mcp::ExchangeError) { host.call("double_sync", "http://example.test") }
      assert_equal 2, attempts
      assert_equal "Sync request failed: RuntimeError: attempt 1", err.message
      assert_equal "echo:still-synced", host.call("echo", "still-synced").out
    ensure
      host&.close
    end
  end

  private

  def write_raw_reply_host(dir, raw_reply)
    path = File.join(dir, "raw_reply_host")
    File.write(path, <<~RUBY)
      #!#{RbConfig.ruby}
      $stdin.binmode
      $stdout.binmode
      $stdout.write("ok 0 0\\n")
      $stdout.flush
      $stdin.gets
      $stdout.write(#{raw_reply.b.inspect})
      $stdout.flush
      exit 0
    RUBY
    File.chmod(0o755, path)
    path
  end

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
          when "double_sync"
            2.times do |i|
              req = "GET #{input}/step#{i}\n".b
              $stdout.write("exchange #{req.bytesize}\n")
              $stdout.write(req)
              $stdout.flush
              resp_len = $stdin.gets.to_i
              read_exact(resp_len)
            end
            send_ok("done")
          else
            send_error("No entry named #{entry}")
          end
        when "boot", "open"
          size = parts[1].to_i
          next_db = read_exact(size).force_encoding(Encoding::UTF_8)
          if File.basename(next_db) == "fail.sqlite3"
            send_error("Cannot open database")
          else
            db = next_db
            send_ok
          end
        else
          exit 2
        end
      end
    RUBY
    File.chmod(0o755, path)
    path
  end
end
