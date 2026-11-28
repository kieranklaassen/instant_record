require "fileutils"
require_relative "app_stage"
require_relative "runner"

module InstantRecord
  class Compiler
    # Copies an emitted Spinel project and adapts it into a single-threaded tree
    # suitable for wasm32-wasi and the native static library.
    class WasmTree
      IGNORE_PATTERNS = %w[build storage node_modules e2e test].freeze
      THREAD_CONSTANTS = %w[Thread Mutex Queue ConditionVariable Fiber].freeze
      THREAD_CONSTANT_RE = /\b(?:#{THREAD_CONSTANTS.join('|')})\b/

      WASM_THREADS_RB = <<~'RUBY'
        # Hand-written (see WasmTree): single-threaded stand-ins for the threading classes the
        # emitted runtime uses. One wasm run handles one request on one thread, so a lock has nothing to
        # exclude, a thread-local is a plain slot, and a background thread is never started.
        class WasmThread
          def self.current
            @current ||= WasmThread.new
          end

          def self.pass
            nil
          end

          def initialize(a = nil, b = nil, &block)
            @locals = {}
          end

          def [](key)
            @locals[key]
          end

          def []=(key, value)
            @locals[key] = value
          end

          def key?(key)
            @locals.key?(key)
          end

          def join(limit = nil)
            self
          end

          def alive?
            false
          end

          def kill
            self
          end
        end

        # WASI has no stack switching, so a Fiber cannot be created. The runtime only builds them for its
        # fiber-per-connection server, which a one-shot run never starts.
        class WasmFiber
          def self.yield(value = nil)
            nil
          end

          def initialize(&block)
            @started = false
          end

          def resume(value = nil)
            nil
          end

          def alive?
            false
          end
        end

        class WasmMutex
          def synchronize
            yield
          end

          def lock
            self
          end

          def unlock
            self
          end

          def locked?
            false
          end

          def owned?
            true
          end

          def try_lock
            true
          end
        end

        class WasmConditionVariable
          def wait(mutex = nil, timeout = nil)
            self
          end

          def signal
            self
          end

          def broadcast
            self
          end
        end

        module Timeout
          class Error < RuntimeError
          end

          def self.timeout(sec, klass = nil, message = nil)
            yield(sec)
          end
        end
      RUBY

      AES_STUB = <<~'RUBY'
          def self.aes_256_gcm_encrypt(key, iv, plain)
            raise NotImplementedError, "AES-256-GCM is not available in the wasm build"
          end

          def self.aes_256_gcm_decrypt(key, iv, ct, tag)
            raise NotImplementedError, "AES-256-GCM is not available in the wasm build"
          end
        end
      RUBY

      CHANGED_METHOD = <<~'RUBY'
            def changed
              changes = changes_to_save
              changes.keys.map { |name| name.to_s }
            end

      RUBY

      SYMBOLIZE_ATTRS = "attrs = attrs.to_h { |k, v| [k.to_s.to_sym, v] } if attrs.is_a?(Hash) && attrs.any? { |k, _| k.is_a?(String) }"

      QUOTING_METHODS = <<~'RUBY'
            def quote_column_name(name)
              "\"" + name.to_s.gsub("\"", "\"\"") + "\""
            end

            def quote_table_name(name)
              quote_column_name(name).gsub(".", "\".\"")
            end

      RUBY

      PRUNED_STUBS = {
        "runtime/action_text.rb" => "module ActionText\nend\n",
        "runtime/action_text_json.rb" => "",
        "runtime/nokogiri_spinel.rb" => "",
        "runtime/rails_html_sanitizer_spinel.rb" => "",
        "runtime/active_storage.rb" => <<~'RUBY',
          module ActiveStorage
            module Routes
              def self.table
                []
              end

              def self.instantiate_controller(_sym)
                nil
              end
            end

            module Previewer
              class VideoPreviewer
              end
            end
          end
        RUBY
        "runtime/active_storage_disk.rb" => "",
        "runtime/active_storage_processor.rb" => "",
        "runtime/active_storage_previewer.rb" => "",
        "runtime/multipart.rb" => "",
        "runtime/cable.rb" => "module Cable\n  def self.upgrade(_req, _res)\n    nil\n  end\nend\n",
        "runtime/action_cable.rb" => "",
        "runtime/turbo_streams.rb" => "",
        "runtime/redis_cable.rb" => "",
        "runtime/faye_websocket.rb" => "module Faye\n  class WebSocket\n  end\nend\n",
        "runtime/sidekiq_redis.rb" => "",
        "runtime/sidekiq_envelope.rb" => "",
        "runtime/sidekiq_worker.rb" => "",
        "runtime/sidekiq_push.rb" => <<~'RUBY',
          module SidekiqPush
            def self.flush_held
              nil
            end

            def self.drop_held
              nil
            end

            def self.enqueue(_name, _queue, _at, _payload)
              nil
            end
          end
        RUBY
        "runtime/solid_queue.rb" => "",
        "runtime/solid_queue_standin.rb" => "",
        "runtime/active_job_serialization.rb" => "",
        "runtime/integration_session.rb" => "",
        "runtime/active_record/tasks.rb" => <<~'RUBY',
          module ActiveRecord
            module Tasks
              module DatabaseTasks
                def self.current_db_config
                  nil
                end

                def self.replace_configs(_configs)
                  nil
                end
              end
            end
          end
        RUBY
        "runtime/active_record/migration_runner.rb" => "",
        "runtime/active_record/schema_reader.rb" => "",
        "runtime/rake/task.rb" => "",
        "runtime/active_record/friendly_id.rb" => "",
        "runtime/active_record/signed_id.rb" => "",
        "runtime/active_record/token_for.rb" => "",
        "runtime/action_controller_page_caching.rb" => <<~'RUBY',
          module ActionController
            class Base
              def self.page_cache_directory
                ""
              end

              def self.perform_caching
                false
              end
            end
          end
        RUBY
        "runtime/action_controller_fragment_caching.rb" => "",
        "runtime/action_controller_json_render.rb" => "",
        "runtime/fragment_cache.rb" => "",
        "runtime/active_support_cache.rb" => "",
        "runtime/active_support_reporters.rb" => "",
        "runtime/i18n_locale.rb" => "",
        "runtime/schematized_json.rb" => "",
        "runtime/user_agent.rb" => <<~'RUBY',
          module UserAgent
            def self.parse(_ua)
              nil
            end

            def self.version_below?(_reported, _floor)
              false
            end
          end
        RUBY
        "runtime/active_support_number_helper.rb" => <<~'RUBY',
          module ActiveSupport
            module NumberHelper
              def self.symbolize_options(opts = {})
                opts
              end

              def self.number_to_currency(n, _opts = {}); n.to_s; end
              def self.number_to_delimited(n, _opts = {}); n.to_s; end
              def self.number_to_human(n, _opts = {}); n.to_s; end
              def self.number_to_human_size(n, _opts = {}); n.to_s; end
              def self.number_to_percentage(n, _opts = {}); n.to_s; end
              def self.number_to_phone(n, _opts = {}); n.to_s; end
              def self.number_to_rounded(n, _opts = {}); n.to_s; end
            end
          end
        RUBY
        "runtime/tep/server.rb" => "",
        "runtime/tep/server_threaded.rb" => "",
        "runtime/tep/server_scheduled.rb" => "",
        "runtime/tep/unix_listener.rb" => "",
        "runtime/tep/thruster_cache.rb" => <<~'RUBY',
          module Tep
            class ThrusterCache
              def answer(_req, _res)
                false
              end

              def store(_req, _res)
                nil
              end
            end

            THRUSTER_CACHE = ThrusterCache.new
          end
        RUBY
        "runtime/tep/presence.rb" => "",
        "runtime/tep/scheduler.rb" => <<~'RUBY',
          module Tep
            class FiberSlot
              def initialize(_fiber)
              end
            end

            module Scheduler
              READ = 1

              def self.io_wait(_fd, _mode, _timeout)
                0
              end
            end
          end
        RUBY
        "runtime/tep/broadcast.rb" => <<~'RUBY',
          module Tep
            module Broadcast
              def self.subscribers_for(_topic)
                []
              end
            end
          end
        RUBY
        "runtime/tep/websocket.rb" => <<~'RUBY'
          module Tep
            module WebSocket
              class Driver
                def initialize(_fd = 0)
                end
              end
            end
          end
        RUBY
      }.freeze

      IGNORE_SET = IGNORE_PATTERNS.to_h { |name| [name, true] }.freeze
      THREAD_REPLACEMENT = 'Wasm\0'.freeze
      TIMEOUT_REQUIRE = 'require "timeout"'.freeze
      TIMEOUT_COMMENT = '# require "timeout"  (wasm: see runtime/wasm_threads.rb)'.freeze
      OPENSSL_REQUIRE = 'require "openssl"'.freeze
      OPENSSL_COMMENT = '# require "openssl"  (wasm: no OpenSSL build)'.freeze
      AES_ANCHOR = "  def self.aes_256_gcm_encrypt".freeze
      SQLITE_PREFIX = "sqlite3_".freeze
      SQLITE_SHIM_RE = /sqlite3_(?:bind_int64|last_insert_rowid)/
      SQLITE_SHIM_REPLACEMENT = 'rh_\0'.freeze
      READ_TRACKER_HOOK = "InstantRecord::ReadTracker.record_sql(sql)".freeze
      READ_TRACKER_MARKER = "(sql".freeze
      READ_TRACKER_RE = /^(\s*)def (?:self\.)?(?:each_row|select_all|select_rows|select_value|select_values|query|exec_query)\(sql\b[^\n]*\)\n/
      READ_TRACKER_REPLACEMENT = "\\0\\1  #{READ_TRACKER_HOOK}\n".freeze
      DATETIME_CAST_RE = /(if name == "(\w+_at)"\n\s+if respond_to\?\(:\2=\)\n\s+self\.\2 = )value\n/
      DATETIME_CAST_REPLACEMENT = ('\1ActiveSupport.cast_datetime(value)' + "\n").freeze
      REMOTE_TIMESTAMP_TARGET = "if !(creating) || @updated_at_raw.nil? || @updated_at_raw.empty?".freeze
      REMOTE_TIMESTAMP_REPLACEMENT = "if (!(creating) && !InstantRecord::Client.applying_remote?) || @updated_at_raw.nil? || @updated_at_raw.empty?".freeze
      UPDATE_BANG_MARKER = "def update!(attrs)\n".freeze
      UPDATE_BANG_RE = /^( *)def update!\(attrs\)\n(?! *attrs = attrs\.to_h )/
      UPDATE_BANG_REPLACEMENT = "\\0\\1  #{SYMBOLIZE_ATTRS}\n".freeze
      CHANGED_ANCHOR = "    def has_changes_to_save?\n".freeze
      QUOTING_ANCHOR = "    def quote_string(str)\n".freeze
      QUOTE_COL_DEF = "def quote_column_name(".freeze
      QUOTE_TABLE_DEF = "def quote_table_name(".freeze
      EACH_WITH_INDEX = "each_with_index".freeze
      RAW_CAP_CALL = "ActionView::ViewHelpers.raw(_cap)".freeze
      RAW_CAP_REPLACEMENT = "io << _cap".freeze
      BOGUS_FORM_ATTR = '#{ActionView::ViewHelpers.tag_attr("form", { data: { turbo: false, action: "submit->issues#submit" } })}'.freeze
      BUTTON_TO_CLASS = 'class=\"#{"button_to"}\">'.freeze
      BUTTON_TO_PATCHED = 'class=\"#{"button_to"}\" data-turbo=\"false\" data-action=\"submit-&gt;issues#submit\">'.freeze
      EMPTY_STR = "".freeze
      RB_EXT = ".rb".freeze
      DOT_PREFIX = ".".freeze
      NEWLINE = "\n".freeze
      REQUIRE_LINE_RE = /^require(?:_relative)? /
      WASM_THREADS_REQUIRE = "require_relative \"runtime/wasm_threads\"\n".freeze
      CREATE_EXCL_TEXT_MODE = File::WRONLY | File::CREAT | File::EXCL
      CREATE_TRUNC_TEXT_MODE = File::WRONLY | File::CREAT | File::TRUNC
      CREATE_EXCL_BIN_MODE = FileCopy::CREATE_EXCL_MODE
      CREATE_TRUNC_BIN_MODE = FileCopy::CREATE_TRUNC_MODE
      SMALL_FILE_THRESHOLD = FileCopy::SMALL_FILE_THRESHOLD

      PRUNED_HEADERS = PRUNED_STUBS.each_with_object({}) do |(rel, stub), by_dir|
        runtime_rel = rel.delete_prefix("runtime/")
        dir = File.dirname(runtime_rel)
        dir = nil if dir == "."
        (by_dir[dir] ||= {})[File.basename(runtime_rel)] = "# Pruned for browser wasm (see WasmTree)\n#{stub}".freeze
      end.each_value(&:freeze).freeze

      def self.build(source:, target:, demo: false)
        new(source: source, target: target, demo: demo).run
      end

      def initialize(source:, target:, demo: false)
        @source = source.to_s
        @target = target.to_s
        @demo = demo
      end

      def run
        remove_if_present(@target)

        @touched = 0
        @pruned_lines = 0
        @wrote_wasm_threads = false
        @seen_required = {}
        @deferred_errors = {}

        source_str = strip_trailing_separators(@source)
        target_str = strip_trailing_separators(@target)
        root_stat = File.stat(source_str)
        seen = {}

        walk_dir(source_str, target_str, root_stat, seen, :root, nil, top: true)
        finalize_and_validate!

        { touched: @touched, pruned_lines: @pruned_lines }
      end

      private

      def target_path(rel)
        File.join(@target, rel)
      end

      def strip_trailing_separators(path)
        str = File.path(path)
        str = str.chomp(File::SEPARATOR) while str.length > 1 && str.end_with?(File::SEPARATOR)
        str
      end

      def remove_if_present(path)
        File.lstat(path)
        FileUtils.rm_rf(path)
      rescue Errno::ENOENT, Errno::ENOTDIR
        nil
      end

      def walk_dir(src_dir, dst_dir, dir_stat, seen, zone, sub_rel, top:)
        dev_seen = (seen[dir_stat.dev] ||= {})
        ino = dir_stat.ino
        return if dev_seen.key?(ino)

        dev_seen[ino] = true
        begin
          begin
            Dir.mkdir(dst_dir)
          rescue Errno::ENOENT
            raise unless top

            FileUtils.mkdir_p(dst_dir)
          rescue Errno::EEXIST
            raise unless File.directory?(dst_dir)
          end

          if top
            target_stat = File.stat(dst_dir)
            (seen[target_stat.dev] ||= {})[target_stat.ino] = true
          end

          pruned_dir_map = (zone == :runtime && @demo) ? PRUNED_HEADERS[sub_rel] : nil

          Dir.each_child(src_dir) do |name|
            next if IGNORE_SET.key?(name)

            src = "#{src_dir}/#{name}"
            dest = "#{dst_dir}/#{name}"
            stat = File.stat(src)

            if stat.directory?
              child_zone, child_sub_rel = next_dir_zone(zone, sub_rel, name)
              walk_dir(src, dest, stat, seen, child_zone, child_sub_rel, top: false)
            else
              process_file(src, dest, stat, zone, sub_rel, name, pruned_dir_map)
            end
          end
        ensure
          dev_seen.delete(ino)
        end
      end

      def next_dir_zone(zone, sub_rel, name)
        case zone
        when :root
          case name
          when "runtime" then [:runtime, nil]
          when "config" then [:config, nil]
          when "app" then [:app, nil]
          else [nil, nil]
          end
        when :app
          case name
          when "models" then [:models, nil]
          when "views" then [:views, nil]
          else [nil, nil]
          end
        when :runtime
          return [nil, nil] if name.start_with?(DOT_PREFIX)

          [:runtime, sub_rel ? "#{sub_rel}/#{name}" : name]
        when :config, :models
          return [nil, nil] if name.start_with?(DOT_PREFIX)

          [zone, nil]
        when :views
          return [nil, nil] if name.start_with?(DOT_PREFIX)
          return [:views_slack, nil] if @demo && name == "slack"

          [:views, nil]
        when :views_slack
          return [nil, nil] if name.start_with?(DOT_PREFIX)
          return [:views_slack_channels, nil] if name == "channels"

          [:views, nil]
        when :views_slack_channels
          return [nil, nil] if name.start_with?(DOT_PREFIX)

          [:views, nil]
        else
          [nil, nil]
        end
      end

      def process_file(src, dest, stat, zone, sub_rel, name, pruned_dir_map)
        case zone
        when :root
          if name == "boot.rb"
            @seen_required[:boot] = true
            text = File.read(src)
            transform_threading_and_timeout!(text)
            transform_boot!(text)
            write_file(dest, text, stat, src, binary: false)
            return
          elsif name == "main_wasm.rb"
            @seen_required[:main_wasm] = true
            text = File.read(src)
            transform_threading_and_timeout!(text)
            write_file(dest, text, stat, src, binary: false)
            return
          end
        when :runtime
          if name.end_with?(RB_EXT) && !name.start_with?(DOT_PREFIX)
            process_runtime_file(src, dest, stat, sub_rel, name, pruned_dir_map)
            return
          end
        when :config
          if name.end_with?(RB_EXT) && !name.start_with?(DOT_PREFIX)
            text = File.read(src)
            transform_threading_and_timeout!(text)
            write_file(dest, text, stat, src, binary: false)
            return
          end
        when :models
          if name.end_with?(RB_EXT) && !name.start_with?(DOT_PREFIX)
            text = File.read(src)
            transform_model!(text)
            write_file(dest, text, stat, src, binary: false)
            return
          end
        when :views, :views_slack, :views_slack_channels
          if name.end_with?(RB_EXT) && !name.start_with?(DOT_PREFIX)
            text = File.read(src)
            transform_emitted_view!(text)
            if zone == :views_slack_channels && name == "_sidebar.rb"
              @seen_required[:slack_sidebar] = true
              text = transform_slack_sidebar(text)
            end
            write_file(dest, text, stat, src, binary: false)
            return
          end
        end

        copy_verbatim_file(src, dest, stat)
      end

      def process_runtime_file(src, dest, stat, sub_rel, name, pruned_dir_map)
        if sub_rel.nil? && name == "wasm_threads.rb"
          text = File.read(src)
          @touched += 1 if text.match?(THREAD_CONSTANT_RE)
          write_file(dest, WASM_THREADS_RB, stat, src, binary: false)
          @wrote_wasm_threads = true
          return
        end

        if pruned_dir_map && (stub = pruned_dir_map[name]) && stat.file?
          text = File.read(src)
          @touched += 1 if text.match?(THREAD_CONSTANT_RE)
          @pruned_lines += text.count(NEWLINE)
          write_file(dest, stub, stat, src, binary: false)
          return
        end

        text = File.read(src)
        transform_threading_and_timeout!(text)

        if sub_rel.nil?
          case name
          when "message_digest.rb"
            @seen_required[:message_digest] = true
            text = transform_message_digest(text)
          when "db.rb"
            @seen_required[:db] = true
            text.gsub!(SQLITE_SHIM_RE, SQLITE_SHIM_REPLACEMENT) if text.include?(SQLITE_PREFIX)
          when "sqlite_adapter.rb"
            transform_read_tracking!(text) if stat.file?
          end
        elsif sub_rel == "active_record"
          case name
          when "base.rb"
            @seen_required[:active_record_base] = true
            transform_active_record_changed!(text)
          when "connection.rb"
            if stat.file?
              @seen_required[:connection] = true
              transform_connection_quoting!(text)
            end
          end
        end

        write_file(dest, text, stat, src, binary: false)
      end

      def copy_verbatim_file(src, dest, stat)
        if stat.file? && stat.size <= SMALL_FILE_THRESHOLD
          write_file(dest, File.binread(src), stat, src, binary: true)
        else
          FileCopy.copy_file(src, dest, stat)
        end
      end

      def write_file(dest, data, stat, src, binary:)
        mode = stat.mode & 0o777
        excl = binary ? CREATE_EXCL_BIN_MODE : CREATE_EXCL_TEXT_MODE
        f = File.open(dest, excl, mode)
        begin
          f.binmode if binary
          f.write(data)
        ensure
          f.close
        end
      rescue Errno::EEXIST
        dest_stat = begin
          File.stat(dest)
        rescue SystemCallError
          nil
        end
        if dest_stat && dest_stat.dev == stat.dev && dest_stat.ino == stat.ino
          raise ArgumentError, "same file: #{src} and #{dest}"
        end

        trunc = binary ? CREATE_TRUNC_BIN_MODE : CREATE_TRUNC_TEXT_MODE
        f = File.open(dest, trunc, mode)
        begin
          f.binmode if binary
          f.write(data)
        ensure
          f.close
        end
      end

      def transform_threading_and_timeout!(text)
        if text.match?(THREAD_CONSTANT_RE)
          text.gsub!(THREAD_CONSTANT_RE, THREAD_REPLACEMENT)
          @touched += 1
        end
        text.gsub!(TIMEOUT_REQUIRE, TIMEOUT_COMMENT) if text.include?(TIMEOUT_REQUIRE)
        text
      end

      def transform_message_digest(text)
        start = text.index(AES_ANCHOR)
        unless start
          @deferred_errors[:message_digest] = "Expected aes_256_gcm_encrypt in #{target_path('runtime/message_digest.rb')}"
          return text
        end

        head = text[0...start]
        head.gsub!(OPENSSL_REQUIRE, OPENSSL_COMMENT) if head.include?(OPENSSL_REQUIRE)
        head << AES_STUB
      end

      def transform_read_tracking!(text)
        return text if text.include?(READ_TRACKER_HOOK) || !text.include?(READ_TRACKER_MARKER)

        text.gsub!(READ_TRACKER_RE, READ_TRACKER_REPLACEMENT) if text.match?(READ_TRACKER_RE)
        text
      end

      def transform_model!(text)
        text.gsub!(DATETIME_CAST_RE, DATETIME_CAST_REPLACEMENT) if text.match?(DATETIME_CAST_RE)
        # Roundhouse's generated fill_timestamps unconditionally stamps
        # updated_at = db_now on every UPDATE, clobbering the server's
        # authoritative timestamp during upsert_from_server. Preserve the
        # incoming server timestamp while applying_remote? is active.
        text.gsub!(REMOTE_TIMESTAMP_TARGET, REMOTE_TIMESTAMP_REPLACEMENT) if text.include?(REMOTE_TIMESTAMP_TARGET)
        # A generated update and initialize turn String keys into Symbols; the
        # generated update! does not, so it saves without the fields and succeeds.
        if text.include?(UPDATE_BANG_MARKER) && text.match?(UPDATE_BANG_RE)
          text.gsub!(UPDATE_BANG_RE, UPDATE_BANG_REPLACEMENT)
        end
        text
      end

      def transform_active_record_changed!(text)
        idx = text.index(CHANGED_ANCHOR)
        unless idx
          @deferred_errors[:active_record_base] = "Expected #{CHANGED_ANCHOR.strip} in #{target_path('runtime/active_record/base.rb')}"
          return text
        end

        text.insert(idx, CHANGED_METHOD)
      end

      # The emitted Connection has no identifier quoting, which SyncWindow's SQL
      # is built with. These quote as Rails does for SQLite.
      def transform_connection_quoting!(text)
        given = (text.include?(QUOTE_COL_DEF) ? 1 : 0) + (text.include?(QUOTE_TABLE_DEF) ? 1 : 0)
        return text if given == 2

        idx = given.zero? ? text.index(QUOTING_ANCHOR) : nil
        unless idx
          @deferred_errors[:connection] = "Expected #{QUOTING_ANCHOR.strip} and both or neither quoting method in #{target_path('runtime/active_record/connection.rb')}"
          return text
        end

        text.insert(idx, QUOTING_METHODS)
      end

      def transform_emitted_view!(text)
        if text.include?(EACH_WITH_INDEX) && text.include?(RAW_CAP_CALL)
          text.gsub!(RAW_CAP_CALL, RAW_CAP_REPLACEMENT)
        end
        if text.include?(BOGUS_FORM_ATTR)
          text.gsub!(BOGUS_FORM_ATTR, EMPTY_STR)
          text.gsub!(BUTTON_TO_CLASS, BUTTON_TO_PATCHED) if text.include?(BUTTON_TO_CLASS)
        end
        text
      end

      def transform_slack_sidebar(text)
        start = text.index("channels.each do |channel|")
        stop = start && text.index("dms.each do", start)
        unless start && stop
          @deferred_errors[:slack_sidebar] = "Expected channel loop in #{target_path('app/views/slack/channels/_sidebar.rb')}"
          return text
        end

        loop_body = text[start...stop]
        loop_body.gsub!(/\bchannel\b/, "channel_row")
        loop_body.gsub!("channel_row == channel_row", "channel_row == channel")
        text[0...start] << loop_body << text[stop..]
      end

      def transform_boot!(text)
        match = text.match(REQUIRE_LINE_RE)
        unless match
          @deferred_errors[:boot] = "Expected require line in #{target_path('boot.rb')}"
          return text
        end

        text.insert(match.begin(0), WASM_THREADS_REQUIRE)
      end

      def finalize_and_validate!
        File.read(target_path("boot.rb")) unless @seen_required[:boot]
        File.read(target_path("main_wasm.rb")) unless @seen_required[:main_wasm]
        File.write(target_path("runtime/wasm_threads.rb"), WASM_THREADS_RB) unless @wrote_wasm_threads
        validate_required_file!(:message_digest, "runtime/message_digest.rb")
        File.read(target_path("runtime/db.rb")) unless @seen_required[:db]
        validate_required_file!(:active_record_base, "runtime/active_record/base.rb")
        unless @seen_required[:connection]
          raise BuildError, "Expected #{target_path('runtime/active_record/connection.rb')}"
        end
        raise BuildError, @deferred_errors[:connection] if @deferred_errors[:connection]

        validate_required_file!(:slack_sidebar, "app/views/slack/channels/_sidebar.rb") if @demo
        raise BuildError, @deferred_errors[:boot] if @deferred_errors[:boot]
      end

      def validate_required_file!(key, rel)
        File.read(target_path(rel)) unless @seen_required[key]
        raise BuildError, @deferred_errors[key] if @deferred_errors[key]
      end
    end
  end
end
