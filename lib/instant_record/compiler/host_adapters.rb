require "digest"
require "fileutils"
require "pathname"
require "prism"
require_relative "ast_lowerer"
require_relative "runner"

module InstantRecord
  class Compiler
    # Swappable target host-adapter modules installed by GemVendor when staging
    # an app for AOT compilation. Each adapter provides the compiled
    # `InstantRecord::Host`, `InstantRecord::RuntimeScoped`, and
    # `InstantRecord::Native` implementations for its target runtime so the gem's
    # own Ruby files need zero literal string edits.
    module HostAdapters
      RUNTIME_SCOPED_SEAM = <<~RUBY
        module InstantRecord
          # Host adapter seam: AstLowerer statically strips server_only blocks and
          # unwraps browser_only / client_only blocks before Roundhouse & Spinel run.
          module RuntimeScoped
            def server_only(&block)
              nil
            end

            def browser_only(&block)
              nil
            end

            def client_only(&block)
              nil
            end
          end
        end
      RUBY

      NATIVE_SEAM = <<~RUBY
        require "instant_record/native/node"
        require "instant_record/native/screen"
      RUBY

      SPINEL_SYNC_ACTIONS_STUB = <<~'RUBY'
        def server_frame = nil
        def enforcing_server_mutator? = false
        def server_authorize_create!(_record) = nil
        def server_finalize_create!(_record) = nil
        def server_authorize_update_before!(_record) = nil
        def server_finalize_update!(_record) = nil
        def server_authorize_destroy!(_record) = nil
        def server_finalize_destroy!(_record) = nil
        def server_note_read(_record) = nil
        def execute_on_server(_name, _args, _mutation_id) = nil
        def register(_klass, _action_name, _block = nil) = nil

        def dispatch(name, _args)
          raise ArgumentError, "Unknown sync_action: " + name
        end
      RUBY

      CRUBY_SYNC_ACTION_METHODS = %i[
        server_frame enforcing_server_mutator?
        server_authorize_create! server_finalize_create!
        server_authorize_update_before! server_finalize_update!
        server_authorize_destroy! server_finalize_destroy!
        server_note_read with_server_frame execute_on_server
        registry reset_registry! register resolve dispatch
        defer_active_job? install_active_job_guard! invoke_callable
      ].freeze

      # Shared installation logic for compiled host adapters.
      module Base
        def install(gem_src:, app_dir:)
          File.write(File.join(app_dir, "lib/instant_record/host.rb"), host_source)
          File.write(File.join(app_dir, "lib/instant_record/runtime_scoped.rb"), RUNTIME_SCOPED_SEAM)
          File.write(File.join(app_dir, "lib/instant_record/native.rb"), NATIVE_SEAM)

          FileUtils.mkdir_p(File.join(app_dir, "sig/instant_record"))
          %w[native.rbs inertia.rbs].each do |rbs|
            FileUtils.cp(
              File.join(gem_src, "sig/instant_record", rbs),
              File.join(app_dir, "sig/instant_record", rbs)
            )
          end

          adapt_compiled_mutate_signatures(app_dir)
          adapt_sync_actions(app_dir)
        end

        private

        # Spinel does not support `**kwargs` splats; rewrite `InstantRecord.mutate`
        # via Prism AST to accept a plain `args = {}` hash.
        def adapt_compiled_mutate_signatures(app_dir)
          path = File.join(app_dir, "lib/instant_record.rb")
          return unless File.file?(path)

          source = File.read(path, encoding: Encoding::UTF_8)
          parsed = Prism.parse(source)
          return unless parsed.success?

          edits = []
          walk_ast(parsed.value) do |node|
            next unless node.is_a?(Prism::DefNode) && node.name == :mutate && node.parameters&.keyword_rest

            indent = AstLowerer.leading_indent(source, node.location.start_offset)
            replacement = <<~RUBY.chomp
              def mutate(mutator_name, args = {}, mutation_id: nil)
              #{indent}  SyncActions.mutate(mutator_name, args, mutation_id: mutation_id)
              #{indent}end
            RUBY
            edits << AstLowerer::Edit.new(
              start_offset: node.location.start_offset,
              end_offset: node.location.end_offset,
              replacement: replacement
            )
          end
          File.write(path, AstLowerer.apply_edits(source, edits)) unless edits.empty?
        end

        # Strip CRuby-only server frame, ActiveJob guard, and dynamic dispatch from
        # `lib/instant_record/sync_actions.rb` using Prism's AST; EntryBuilder emits
        # the static `case` dispatcher in `main_*.rb`.
        def adapt_sync_actions(app_dir)
          path = File.join(app_dir, "lib/instant_record/sync_actions.rb")
          return unless File.file?(path)

          source = File.read(path, encoding: Encoding::UTF_8)
          parsed = Prism.parse(source)
          raise BuildError, "Cannot parse lib/instant_record/sync_actions.rb" unless parsed.success?

          edits = []
          stub_inserted = false
          walk_ast(parsed.value) do |node|
            if node.is_a?(Prism::ClassNode) && AstLowerer.constant_name(node.constant_path) == "ServerFrame"
              edits << delete_lines_edit(source, node)
              next :skip
            elsif node.is_a?(Prism::ModuleNode) && AstLowerer.constant_name(node.constant_path) == "ActiveJobCommitGuard"
              edits << delete_lines_edit(source, node)
              next :skip
            elsif node.is_a?(Prism::DefNode) && node.name == :perform_sync_action && node.parameters&.keyword_rest
              indent = AstLowerer.leading_indent(source, node.location.start_offset)
              replacement = <<~RUBY.chomp
                def perform_sync_action(action_name, args = {}, mutation_id: nil)
                #{indent}  InstantRecord::SyncActions.mutate("\#{name}.\#{action_name}", args, mutation_id: mutation_id)
                #{indent}end
              RUBY
              edits << AstLowerer::Edit.new(start_offset: node.location.start_offset, end_offset: node.location.end_offset, replacement: replacement)
              next :skip
            elsif node.is_a?(Prism::DefNode) && node.name == :mutate && node.parameters&.keyword_rest
              indent = AstLowerer.leading_indent(source, node.location.start_offset)
              # Rewrite parameter list and remove `merged = ...` line inside body.
              sig_end = node.rparen_loc ? node.rparen_loc.end_offset : node.parameters.location.end_offset
              edits << AstLowerer::Edit.new(
                start_offset: node.location.start_offset,
                end_offset: sig_end,
                replacement: "def mutate(mutator_name, args = {}, mutation_id: nil)"
              )
              Array(node.body&.body).each do |stmt|
                if stmt.is_a?(Prism::LocalVariableWriteNode) && stmt.name == :merged
                  edits << delete_lines_edit(source, stmt)
                elsif stmt.is_a?(Prism::LocalVariableWriteNode) && stmt.name == :normalized
                  edits << AstLowerer::Edit.new(
                    start_offset: stmt.location.start_offset,
                    end_offset: stmt.location.end_offset,
                    replacement: "normalized = normalize_args(args)"
                  )
                end
              end
              next :skip
            elsif node.is_a?(Prism::DefNode) && CRUBY_SYNC_ACTION_METHODS.include?(node.name)
              if !stub_inserted
                stub_inserted = true
                indent = AstLowerer.leading_indent(source, node.location.start_offset)
                stub = SPINEL_SYNC_ACTIONS_STUB.lines.map { |l| l.strip.empty? ? "\n" : "#{indent}#{l}" }.join
                edits << AstLowerer::Edit.new(
                  start_offset: AstLowerer.line_start_of(source, node.location.start_offset),
                  end_offset: AstLowerer.line_end_after(source, node.location.end_offset),
                  replacement: stub
                )
              else
                edits << delete_lines_edit(source, node)
              end
              next :skip
            end
          end

          adapted = AstLowerer.apply_edits(source, edits)
          raise BuildError, "Invalid Ruby after adapting sync_actions.rb" unless Prism.parse(adapted).success?

          File.write(path, adapted)
        end

        def delete_lines_edit(source, node)
          AstLowerer::Edit.new(
            start_offset: AstLowerer.line_start_of(source, node.location.start_offset),
            end_offset: AstLowerer.line_end_after(source, node.location.end_offset),
            replacement: ""
          )
        end

        def walk_ast(node, &block)
          return if node.nil?

          return if yield(node) == :skip

          node.compact_child_nodes.each { |child| walk_ast(child, &block) }
        end
      end

      # Browser wasm32-wasi reactor host: communicates with the dedicated worker
      # through virtual `/host/*` files.
      module Wasm
        extend Base

        HOST_SOURCE = <<~RUBY
          module InstantRecord
            # Compiled wasm32-wasi host adapter (see Compiler::HostAdapters::Wasm).
            module Host
              module_function

              def browser? = true

              def load_engine = nil

              def load_inertia_renderer = nil

              def load_branch_store = nil

              def install_active_job_guard = nil

              def with_savepoint(&block)
                @savepoint_seq = (@savepoint_seq || 0) + 1
                sp = "ir_sp_" + @savepoint_seq.to_s
                Db.exec("SAVEPOINT " + sp)
                begin
                  result = block.call
                  Db.exec("RELEASE SAVEPOINT " + sp)
                  result
                rescue StandardError => error
                  Db.exec("ROLLBACK TO SAVEPOINT " + sp)
                  Db.exec("RELEASE SAVEPOINT " + sp)
                  raise error
                end
              end

              def default_mount_path = InstantRecord::DEFAULT_MOUNT_PATH

              def resolve_syncable_model(_record_type) = nil

              def discover_syncable_models = []

              # Compiled models initialize a new record's id to "", not nil.
              def blank_id?(id)
                id.blank?
              end

              def read_channel(name)
                File.read("/host/\#{name}")
              end

              def write_channel(name, body)
                File.write("/host/\#{name}", body)
              end
            end
          end
        RUBY

        module_function

        def target = :wasm
        def host_source = HOST_SOURCE
      end

      # Native static-library host (macOS host binary / iOS simulator / iPhone):
      # communicates through NativeHost FFI calls (`native_shim.c`).
      module Native
        extend Base

        HOST_SOURCE = <<~RUBY
          module InstantRecord
            # Compiled native host adapter (see Compiler::HostAdapters::Native).
            module Host
              module_function

              def browser? = true

              def load_engine = nil

              def load_inertia_renderer = nil

              def load_branch_store = nil

              def install_active_job_guard = nil

              def with_savepoint(&block)
                @savepoint_seq = (@savepoint_seq || 0) + 1
                sp = "ir_sp_" + @savepoint_seq.to_s
                Db.exec("SAVEPOINT " + sp)
                begin
                  result = block.call
                  Db.exec("RELEASE SAVEPOINT " + sp)
                  result
                rescue StandardError => error
                  Db.exec("ROLLBACK TO SAVEPOINT " + sp)
                  Db.exec("RELEASE SAVEPOINT " + sp)
                  raise error
                end
              end

              def default_mount_path = InstantRecord::DEFAULT_MOUNT_PATH

              def resolve_syncable_model(_record_type) = nil

              def discover_syncable_models = []

              # Compiled models initialize a new record's id to "", not nil.
              def blank_id?(id)
                id.blank?
              end

              def read_channel(name)
                NativeHost.ir_host_take(name)
              end

              def write_channel(name, body)
                NativeHost.ir_host_give(name, body)
              end
            end
          end
        RUBY

        module_function

        def target = :native
        def host_source = HOST_SOURCE
      end

      # Demo-specific seams isolated from GemVendor core vendoring. Ruby edits use
      # Prism AST rewrites rather than literal string substitution.
      module Demo
        SERVER_URL_ROUTES = {
          slack_reset_path: "/slack/reset",
          auth_session_path: "/auth/session",
          auth_session_sign_out_path: "/auth/session/sign_out"
        }.freeze

        module_function

        def apply(app_dir:)
          fingerprint_stylesheets(app_dir)
          version_inbox_bundle(app_dir)
          adapt_demo_views(app_dir)
          rewrite_server_url_helpers(app_dir)
          coerce_slack_thread_replies(app_dir)
        end

        def fingerprint_stylesheets(app_dir)
          stylesheets_dir = File.join(app_dir, "app/assets/stylesheets")
          return unless File.directory?(stylesheets_dir)

          Dir.glob("*.css", base: stylesheets_dir).sort.each do |name|
            sheet = File.join(stylesheets_dir, name)
            digest = Digest::SHA256.file(sheet).hexdigest[0, 10]
            ext = File.extname(sheet)
            stem = File.basename(sheet, ext)
            File.rename(sheet, File.join(stylesheets_dir, "#{stem}-#{digest}#{ext}"))
          end
        end

        def version_inbox_bundle(app_dir)
          bundle = File.join(app_dir, "app/assets/builds/inbox.js")
          view = File.join(app_dir, "app/views/email/mailboxes/index.html.erb")
          return unless File.file?(bundle) && File.file?(view)

          digest = Digest::SHA256.file(bundle).hexdigest[0, 10]
          source = File.read(view)
          target = '<%= asset_path("inbox.js") %>'
          replacement = "/assets/inbox.js?v=#{digest}"
          if source.include?(target)
            File.write(view, source.sub(target) { replacement })
          elsif !source.include?(replacement)
            raise BuildError, "demo seam did not apply: app/views/email/mailboxes/index.html.erb"
          end
        end

        def adapt_demo_views(app_dir)
          layout_path = File.join(app_dir, "app/views/layouts/application.html.erb")
          if File.file?(layout_path)
            source = File.read(layout_path)
            source = source.gsub('<span class="micro-label">Local-first Rails demos —', '<span class="micro-label"><a href="/">All demos</a> ·')
            source = source.gsub('<%= source_path(page: controller_path, view: action_name) %>', "/source")
            source = source.gsub("Read live out of app.wasm — not a snippet", "View the source for this build")
            source = source.gsub('demo-<%= controller_path.split("/").first %>', "demo-<%= content_for(:demo_scope) %>")
            source = source.gsub('<% demo = controller_path.split("/").first %>', "<% demo = content_for(:demo_scope).to_s %>")
            File.write(layout_path, source)
          end

          views_dir = File.join(app_dir, "app/views")
          views_root = Pathname(views_dir)
          Dir.glob("**/*.html.erb", base: views_dir).sort.each do |rel|
            view = views_root.join(rel)
            next if view.basename.to_s.start_with?("_") || view.parent.basename.to_s == "layouts"

            scope = Pathname(rel).each_filename.first
            view.write("<% content_for(:demo_scope, \"#{scope}\") %>\n" + view.read)
          end
        end

        # Rewrites `InstantRecord.server_url(...)` calls in demo helpers into static
        # network-marked path literals using Prism's AST.
        def rewrite_server_url_helpers(app_dir)
          %w[app/helpers/slack_helper.rb app/helpers/auth_helper.rb].each do |rel|
            path = File.join(app_dir, rel)
            next unless File.file?(path)

            source = File.read(path, encoding: Encoding::UTF_8)
            parsed = Prism.parse(source)
            raise BuildError, "Cannot parse #{rel}" unless parsed.success?

            edits = []
            walk_nodes(parsed.value) do |node|
              next unless node.is_a?(Prism::CallNode) && node.name == :server_url
              next unless %w[InstantRecord ::InstantRecord].include?(AstLowerer.constant_name(node.receiver))

              args = node.arguments&.arguments
              next unless args&.length == 1

              resolved = resolve_demo_route(args.first)
              next unless resolved

              edits << AstLowerer::Edit.new(
                start_offset: node.location.start_offset,
                end_offset: node.location.end_offset,
                replacement: %("#{resolved}?#{InstantRecord::NETWORK_MARKER}")
              )
            end

            raise BuildError, "demo seam did not apply: #{rel}: no InstantRecord.server_url calls rewritten" if edits.empty?

            File.write(path, AstLowerer.apply_edits(source, edits))
          end
        end

        # Compiled code needs a single array type across both branches of the
        # `@thread_parent ? <relation> : []` ternary.
        def coerce_slack_thread_replies(app_dir)
          rel = "app/controllers/slack/channels_controller.rb"
          path = File.join(app_dir, rel)
          return unless File.file?(path)

          source = File.read(path, encoding: Encoding::UTF_8)
          parsed = Prism.parse(source)
          raise BuildError, "Cannot parse #{rel}" unless parsed.success?

          edits = []
          walk_nodes(parsed.value) do |node|
            next unless node.is_a?(Prism::IfNode) && node.if_keyword_loc.nil?
            next unless node.predicate.is_a?(Prism::InstanceVariableReadNode) && node.predicate.name == :@thread_parent

            else_body = node.subsequent&.statements&.body
            next unless else_body&.length == 1 && else_body.first.is_a?(Prism::ArrayNode) && else_body.first.elements.empty?

            then_body = node.statements&.body
            next unless then_body&.length == 1 && then_body.first.is_a?(Prism::CallNode)
            next if then_body.first.name == :to_a

            end_off = then_body.first.location.end_offset
            edits << AstLowerer::Edit.new(start_offset: end_off, end_offset: end_off, replacement: ".to_a")
          end

          raise BuildError, "demo seam did not apply: #{rel}: @thread_parent ternary not found" if edits.empty?

          File.write(path, AstLowerer.apply_edits(source, edits))
        end

        def resolve_demo_route(arg)
          case arg
          when Prism::StringNode
            arg.unescaped
          when Prism::CallNode
            SERVER_URL_ROUTES[arg.name] if arg.receiver.nil? && arg.arguments.nil?
          end
        end

        def walk_nodes(node, &block)
          return if node.nil?

          yield node
          node.compact_child_nodes.each { |child| walk_nodes(child, &block) }
        end
      end

      module_function

      def for(target)
        return target if target.respond_to?(:install) && target.respond_to?(:host_source)

        case target.to_sym
        when :wasm then Wasm
        when :native, :iphonesimulator, :iphoneos then Native
        else
          raise ArgumentError, "Unknown host adapter target: #{target.inspect}"
        end
      end
    end
  end
end
