require "fileutils"
require "open3"

module InstantRecord
  module Mcp
    # Persistent driver for the screenless native `host` binary compiled by
    # InstantRecord::Compiler::NativeBuild (compiled/pipeline/native/host.c).
    #
    # Protocol (byte-counted over binary stdin/stdout):
    #   driver -> host:  call <entry> <bytes>\n<input>
    #                    boot <bytes>\n<path>
    #                    open <bytes>\n<path>
    #   host -> driver:  ok <out_bytes> <notice_bytes>\n<out><notice>
    #                    error <bytes>\n<message>
    #                    exchange <bytes>\n<request>
    #   driver -> host:  <response_bytes>\n<response>
    class HostProcess
      Result = Struct.new(:out, :notice, keyword_init: true)
      ENTRY_PATTERN = /\A[a-z][a-z0-9_]{0,30}\z/
      MAX_STDERR_LINES = 50

      attr_reader :binary, :database_path

      def initialize(binary:, database:, exchange: nil, chdir: nil, err: nil)
        @binary = File.expand_path(binary.to_s)
        unless File.file?(@binary) && File.executable?(@binary)
          raise ArgumentError, "Native host binary is not executable: #{@binary}. Build it with `bin/rails instant_record:native`."
        end

        @database_path = database.nil? || database == "-" ? nil : File.expand_path(database.to_s)
        FileUtils.mkdir_p(File.dirname(@database_path)) if @database_path
        @chdir = chdir ? File.expand_path(chdir.to_s) : (@database_path ? File.dirname(@database_path) : Dir.pwd)
        FileUtils.mkdir_p(@chdir)

        @exchange = exchange
        @err = err
        @mutex = Mutex.new
        @stderr_mutex = Mutex.new
        @stderr_lines = []
        @closed = false

        spawn_process!
      end

      def alive?
        !@closed && @wait_thread&.alive?
      end

      def stderr_tail
        @stderr_mutex.synchronize { @stderr_lines.join }
      end

      def call(entry, input = "")
        entry_name = entry.to_s
        raise ArgumentError, "Invalid native entry name: #{entry_name.inspect}" unless ENTRY_PATTERN.match?(entry_name)

        @mutex.synchronize do
          ensure_open!
          payload = input.to_s.b
          write_frame("call #{entry_name} #{payload.bytesize}\n", payload)
          read_reply
        end
      end

      def boot(path)
        switch_database("boot", path)
      end

      def open(path)
        switch_database("open", path)
      end

      def close
        @mutex.synchronize do
          return if @closed

          @closed = true
          begin
            close_io(@stdin)
            reap_process
          ensure
            begin
              @stderr_thread&.join(1)
            ensure
              close_io(@stdout)
              close_io(@stderr)
            end
          end
        end
      end

      private

      def spawn_process!
        @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(@binary, @database_path || "-", chdir: @chdir)
        @stdin.binmode
        @stdout.binmode
        @stderr.binmode
        start_stderr_drain
        read_reply
      rescue StandardError
        close
        raise
      end

      def start_stderr_drain
        @stderr_thread = Thread.new do
          while (line = @stderr.gets)
            line.force_encoding(Encoding::UTF_8)
            line = line.scrub
            @stderr_mutex.synchronize do
              @stderr_lines << line
              @stderr_lines.shift while @stderr_lines.size > MAX_STDERR_LINES
            end
            @err&.write(line)
          end
        rescue IOError
          nil
        end
      end

      def switch_database(verb, path)
        expanded = File.expand_path(path.to_s)
        FileUtils.mkdir_p(File.dirname(expanded))
        @mutex.synchronize do
          result = send_path(verb, expanded)
          @database_path = expanded
          result
        end
      end

      def send_path(verb, path)
        ensure_open!
        bytes = path.b
        write_frame("#{verb} #{bytes.bytesize}\n", bytes)
        read_reply
      end

      def reap_process
        return unless @wait_thread&.alive?
        return if @wait_thread.join(2)

        signal_process("TERM")
        return if @wait_thread.join(1)

        signal_process("KILL")
        @wait_thread.join(1)
      end

      def signal_process(signal)
        pid = @wait_thread.pid
        Process.kill(signal, pid) if pid
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def close_io(io)
        io.close unless io.nil? || io.closed?
      rescue IOError, Errno::EPIPE
        nil
      end

      def ensure_open!
        raise HostCrashedError, "Native host process is closed" if @closed
      end

      def read_reply
        failed_exchange = nil
        loop do
          line = read_header_line
          parts = line.strip.split
          case parts[0]
          when "ok"
            return read_ok_frame(parts, line, failed_exchange)
          when "exchange"
            exchange_failure = read_exchange_frame(parts, line)
            failed_exchange ||= exchange_failure
          when "error"
            read_error_frame(parts, line, failed_exchange)
          else
            raise HostCrashedError, "Unexpected response from native host: #{line.inspect}"
          end
        end
      rescue ArgumentError, TypeError => e
        raise HostCrashedError, "Invalid frame header from native host: #{e.message}"
      rescue Errno::EPIPE, IOError => e
        raise HostCrashedError, "Native host pipe error: #{e.message}"
      end

      def read_header_line
        line = @stdout.gets
        return line unless line.nil?

        tail = stderr_tail.strip
        detail = tail.empty? ? "unexpected EOF" : "unexpected EOF (#{tail})"
        raise HostCrashedError, "Native host exited: #{detail}"
      end

      def read_ok_frame(parts, line, failed_exchange)
        raise HostCrashedError, "Malformed ok frame from native host: #{line.inspect}" unless parts.size >= 3

        out_len = parse_frame_length(parts[1])
        notice_len = parse_frame_length(parts[2])
        out = read_text(out_len)
        notice = read_text(notice_len)
        raise failed_exchange if failed_exchange

        Result.new(out: out, notice: notice)
      end

      def read_exchange_frame(parts, line)
        raise HostCrashedError, "Malformed exchange frame from native host: #{line.inspect}" unless parts.size >= 2

        req_len = parse_frame_length(parts[1])
        request = read_exact(@stdout, req_len).force_encoding(Encoding::UTF_8)
        failure = nil
        begin
          answer = (@exchange ? @exchange.call(request) : HttpExchange::OFFLINE_REPLY).to_s.b
        rescue StandardError => e
          # The host waits for an answer, and its reply is read before this
          # is raised, so the next call finds it ready.
          failure = exchange_error(e)
          answer = HttpExchange::OFFLINE_REPLY
        end
        write_frame("#{answer.bytesize}\n", answer)
        failure
      end

      def read_error_frame(parts, line, failed_exchange)
        raise HostCrashedError, "Malformed error frame from native host: #{line.inspect}" unless parts.size >= 2

        err_len = parse_frame_length(parts[1])
        # The host cuts a long message by bytes, perhaps inside a character.
        message = read_text(err_len)
        raise failed_exchange || HostError.new(message)
      end

      def parse_frame_length(raw)
        length = Integer(raw, 10)
        raise ArgumentError, "negative frame length: #{raw.inspect}" if length.negative?

        length
      end

      def exchange_error(error)
        message = String.new(error.message, encoding: Encoding::UTF_8).scrub
        ExchangeError.new("Sync request failed: #{error.class}: #{message}")
      end

      def read_text(length) = read_exact(@stdout, length).force_encoding(Encoding::UTF_8).scrub

      def read_exact(io, length)
        return "".b if length <= 0

        buffer = String.new(capacity: length, encoding: Encoding::BINARY)
        remaining = length
        while remaining > 0
          chunk = io.read(remaining)
          if chunk.nil? || chunk.empty?
            raise HostCrashedError, "Native host closed stream mid-frame (expected #{length} bytes, got #{buffer.bytesize})"
          end

          buffer << chunk
          remaining -= chunk.bytesize
        end
        buffer
      end

      def write_frame(header, bytes)
        write_all(header)
        write_all(bytes)
        @stdin.flush
      rescue Errno::EPIPE, IOError => e
        raise HostCrashedError, "Native host pipe error: #{e.message}"
      end

      def write_all(bytes)
        written = 0
        total = bytes.bytesize
        while written < total
          written += @stdin.write(bytes.byteslice(written, total - written))
        end
      end
    end
  end
end
