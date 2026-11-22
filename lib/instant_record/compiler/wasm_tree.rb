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

      def self.build(source:, target:, demo: false)
        new(source: source, target: target, demo: demo).run
      end

      def initialize(source:, target:, demo: false)
        @source = source.to_s
        @target = target.to_s
        @demo = demo
      end

      def run
        FileUtils.rm_rf(@target)
        FileCopy.copy_tree(@source, @target, ignore: IGNORE_PATTERNS)

        paths = runtime_paths
        touched = adapt_threading_and_timeout(paths)
        patch_message_digest
        patch_sqlite_shims
        patch_model_datetime_casts
        patch_model_remote_timestamps
        patch_active_record_changed
        patch_emitted_views
        patch_slack_sidebar if @demo
        prepend_wasm_threads_require
        pruned_lines = @demo ? prune_dead_subsystems : 0

        { touched: touched, pruned_lines: pruned_lines }
      end

      private

      def runtime_paths
        paths = %w[boot.rb main_wasm.rb].map { |name| File.join(@target, name) }
        %w[runtime config].each do |folder|
          dir = File.join(@target, folder)
          next unless File.directory?(dir)

          paths.concat(Dir.glob("**/*.rb", base: dir).sort.map { |rel| File.join(dir, rel) })
        end
        paths
      end

      def adapt_threading_and_timeout(paths)
        touched = 0
        paths.each do |path|
          text = File.read(path)
          renamed = text.gsub(THREAD_CONSTANT_RE, 'Wasm\0')
          touched += 1 if renamed != text
          updated = renamed.gsub('require "timeout"', '# require "timeout"  (wasm: see runtime/wasm_threads.rb)')
          File.write(path, updated) if updated != text
        end
        File.write(File.join(@target, "runtime/wasm_threads.rb"), WASM_THREADS_RB)
        touched
      end

      def patch_message_digest
        path = File.join(@target, "runtime/message_digest.rb")
        text = File.read(path)
        start = text.index("  def self.aes_256_gcm_encrypt")
        raise BuildError, "Expected aes_256_gcm_encrypt in #{path}" unless start

        head = text[0...start].gsub('require "openssl"', '# require "openssl"  (wasm: no OpenSSL build)')
        File.write(path, head + AES_STUB)
      end

      def patch_sqlite_shims
        path = File.join(@target, "runtime/db.rb")
        text = File.read(path)
        %w[sqlite3_bind_int64 sqlite3_last_insert_rowid].each do |name|
          text = text.gsub(name, "rh_#{name}")
        end
        File.write(path, text)
      end

      def patch_model_datetime_casts
        models_dir = File.join(@target, "app/models")
        return unless File.directory?(models_dir)

        Dir.glob("**/*.rb", base: models_dir).sort.each do |rel|
          path = File.join(models_dir, rel)
          text = File.read(path)
          fixed = text.gsub(
            /(if name == "(\w+_at)"\n\s+if respond_to\?\(:\2=\)\n\s+self\.\2 = )value\n/,
            '\1ActiveSupport.cast_datetime(value)' + "\n"
          )
          File.write(path, fixed) if fixed != text
        end
      end

      def patch_model_remote_timestamps
        models_dir = File.join(@target, "app/models")
        return unless File.directory?(models_dir)

        Dir.glob("**/*.rb", base: models_dir).sort.each do |rel|
          path = File.join(models_dir, rel)
          text = File.read(path)
          # Roundhouse's generated fill_timestamps unconditionally stamps
          # updated_at = db_now on every UPDATE, clobbering the server's
          # authoritative timestamp during upsert_from_server. Preserve the
          # incoming server timestamp while applying_remote? is active.
          fixed = text.gsub(
            "if !(creating) || @updated_at_raw.nil? || @updated_at_raw.empty?",
            "if (!(creating) && !InstantRecord::Client.applying_remote?) || @updated_at_raw.nil? || @updated_at_raw.empty?"
          )
          File.write(path, fixed) if fixed != text
        end
      end

      def patch_active_record_changed
        path = File.join(@target, "runtime/active_record/base.rb")
        text = File.read(path)
        anchor = "    def has_changes_to_save?\n"
        raise BuildError, "Expected #{anchor.strip} in #{path}" unless text.include?(anchor)

        File.write(path, text.sub(anchor) { CHANGED_METHOD + anchor })
      end

      def patch_emitted_views
        views_dir = File.join(@target, "app/views")
        return unless File.directory?(views_dir)

        bogus = '#{ActionView::ViewHelpers.tag_attr("form", { data: { turbo: false, action: "submit->issues#submit" } })}'
        Dir.glob("**/*.rb", base: views_dir).sort.each do |rel|
          path = File.join(views_dir, rel)
          text = File.read(path)
          updated = text
          if updated.include?("each_with_index") && updated.include?("ActionView::ViewHelpers.raw(_cap)")
            updated = updated.gsub("ActionView::ViewHelpers.raw(_cap)", "io << _cap")
          end
          if updated.include?(bogus)
            updated = updated.gsub(bogus, "")
            updated = updated.gsub(
              'class=\"#{"button_to"}\">',
              'class=\"#{"button_to"}\" data-turbo=\"false\" data-action=\"submit-&gt;issues#submit\">'
            )
          end
          File.write(path, updated) if updated != text
        end
      end

      def patch_slack_sidebar
        sidebar = File.join(@target, "app/views/slack/channels/_sidebar.rb")
        text = File.read(sidebar)
        start = text.index("channels.each do |channel|")
        stop = start && text.index("dms.each do", start)
        raise BuildError, "Expected channel loop in #{sidebar}" unless start && stop

        loop_body = text[start...stop].gsub(/\bchannel\b/, "channel_row").gsub("channel_row == channel_row", "channel_row == channel")
        File.write(sidebar, text[0...start] + loop_body + text[stop..])
      end

      def prepend_wasm_threads_require
        boot = File.join(@target, "boot.rb")
        text = File.read(boot)
        match = text.match(/^require(?:_relative)? /)
        raise BuildError, "Expected require line in #{boot}" unless match

        first = match.begin(0)
        File.write(boot, text[0...first] + "require_relative \"runtime/wasm_threads\"\n" + text[first..])
      end

      def prune_dead_subsystems
        pruned_lines = 0
        PRUNED_STUBS.each do |rel, stub|
          path = File.join(@target, rel)
          next unless File.file?(path)

          pruned_lines += File.read(path).count("\n")
          File.write(path, "# Pruned for browser wasm (see WasmTree)\n#{stub}")
        end
        pruned_lines
      end
    end
  end
end
