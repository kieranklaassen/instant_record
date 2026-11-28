require "digest"
require "fileutils"
require "pathname"
require "prism"
require_relative "ast_lowerer"
require_relative "runner"

module InstantRecord
  NETWORK_MARKER = "instant_record_network=1".freeze unless const_defined?(:NETWORK_MARKER)

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

      CRUBY_SYNC_ACTION_METHODS_MAP = CRUBY_SYNC_ACTION_METHODS.each_with_object({}) { |m, h| h[m] = true }.freeze
      private_constant :CRUBY_SYNC_ACTION_METHODS_MAP

      # Fast Prism::Visitor base with leaf no-ops and direct container dispatch
      # to avoid per-node `compact_child_nodes` array allocations.
      class FastVisitor < Prism::Visitor
        def visit_string_node(_); end
        def visit_symbol_node(_); end
        def visit_integer_node(_); end
        def visit_float_node(_); end
        def visit_true_node(_); end
        def visit_false_node(_); end
        def visit_nil_node(_); end
        def visit_self_node(_); end
        def visit_local_variable_read_node(_); end
        def visit_instance_variable_read_node(_); end
        def visit_class_variable_read_node(_); end
        def visit_global_variable_read_node(_); end
        def visit_constant_read_node(_); end
        def visit_required_parameter_node(_); end
        def visit_required_keyword_parameter_node(_); end
        def visit_local_variable_target_node(_); end
        def visit_instance_variable_target_node(_); end
        def visit_constant_target_node(_); end
        def visit_regular_expression_node(_); end

        def visit_program_node(node)
          node.statements.accept(self)
        end

        def visit_statements_node(node)
          node.body.each { |s| s.accept(self) }
        end

        def visit_arguments_node(node)
          node.arguments.each { |a| a.accept(self) }
        end

        def visit_assoc_node(node)
          node.key.accept(self)
          node.value.accept(self)
        end

        def visit_keyword_hash_node(node)
          node.elements.each { |e| e.accept(self) }
        end

        def visit_hash_node(node)
          node.elements.each { |e| e.accept(self) }
        end

        def visit_array_node(node)
          node.elements.each { |e| e.accept(self) }
        end

        def visit_local_variable_write_node(node)
          node.value.accept(self)
        end

        def visit_instance_variable_write_node(node)
          node.value.accept(self)
        end

        def visit_constant_path_node(node)
          node.parent&.accept(self)
        end

        def visit_interpolated_string_node(node)
          node.parts.each { |p| p.accept(self) }
        end

        def visit_embedded_statements_node(node)
          node.statements&.accept(self)
        end

        def visit_parentheses_node(node)
          node.body&.accept(self)
        end

        def visit_return_node(node)
          node.arguments&.accept(self)
        end

        def visit_and_node(node)
          node.left.accept(self)
          node.right.accept(self)
        end

        def visit_or_node(node)
          node.left.accept(self)
          node.right.accept(self)
        end

        def visit_begin_node(node)
          node.statements&.accept(self)
          node.rescue_clause&.accept(self)
          node.else_clause&.accept(self)
          node.ensure_clause&.accept(self)
        end

        def visit_rescue_node(node)
          node.exceptions.each { |e| e.accept(self) }
          node.reference&.accept(self)
          node.statements&.accept(self)
          node.subsequent&.accept(self)
        end

        def visit_else_node(node)
          node.statements&.accept(self)
        end

        def visit_ensure_node(node)
          node.statements&.accept(self)
        end

        def visit_block_node(node)
          node.parameters&.accept(self)
          node.body&.accept(self)
        end

        def visit_parameters_node(node)
          node.optionals.each { |o| o.accept(self) }
          node.keywords.each { |k| k.accept(self) }
        end

        def visit_optional_parameter_node(node)
          node.value.accept(self)
        end

        def visit_optional_keyword_parameter_node(node)
          node.value.accept(self)
        end

        def visit_block_parameters_node(node)
          node.parameters&.accept(self)
        end

        def visit_def_node(node)
          node.receiver&.accept(self)
          node.parameters&.accept(self)
          node.body&.accept(self)
        end

        def visit_class_node(node)
          node.constant_path.accept(self)
          node.superclass&.accept(self)
          node.body&.accept(self)
        end

        def visit_module_node(node)
          node.constant_path.accept(self)
          node.body&.accept(self)
        end

        def visit_call_node(node)
          node.receiver&.accept(self)
          node.arguments&.accept(self)
          node.block&.accept(self)
        end

        def visit_if_node(node)
          node.predicate.accept(self)
          node.statements&.accept(self)
          node.subsequent&.accept(self)
        end

        def visit_unless_node(node)
          node.predicate.accept(self)
          node.statements&.accept(self)
          node.else_clause&.accept(self)
        end
      end
      private_constant :FastVisitor

      class MutateDefVisitor < FastVisitor
        def initialize(adapter, source, edits)
          @adapter = adapter
          @source = source
          @edits = edits
        end

        def visit_def_node(node)
          if node.name == :mutate && node.parameters&.keyword_rest
            @edits << @adapter.send(
              :replace_def_edit,
              @source, node,
              signature: "mutate(mutator_name, args = {}, mutation_id: nil)",
              body: "SyncActions.mutate(mutator_name, args, mutation_id: mutation_id)"
            )
          end
          super
        end
      end
      private_constant :MutateDefVisitor

      class SyncActionsVisitor < FastVisitor
        def initialize(adapter, source, edits)
          @adapter = adapter
          @source = source
          @edits = edits
          @stub_inserted = false
        end

        def visit_class_node(node)
          if AstLowerer.constant_name(node.constant_path) == "ServerFrame"
            @edits << @adapter.send(:delete_lines_edit, @source, node)
            return
          end
          super
        end

        def visit_module_node(node)
          if AstLowerer.constant_name(node.constant_path) == "ActiveJobCommitGuard"
            @edits << @adapter.send(:delete_lines_edit, @source, node)
            return
          end
          super
        end

        def visit_def_node(node)
          name = node.name
          if name == :perform_sync_action && node.parameters&.keyword_rest
            @edits << @adapter.send(
              :replace_def_edit,
              @source, node,
              signature: "perform_sync_action(action_name, args = {}, mutation_id: nil)",
              body: 'InstantRecord::SyncActions.mutate("#{name}.#{action_name}", args, mutation_id: mutation_id)'
            )
            return
          elsif name == :mutate && node.parameters&.keyword_rest
            @edits.concat(@adapter.send(:sync_mutate_edits, @source, node))
            return
          elsif CRUBY_SYNC_ACTION_METHODS_MAP[name]
            @edits << (@stub_inserted ? @adapter.send(:delete_lines_edit, @source, node) : @adapter.send(:sync_actions_stub_edit, @source, node))
            @stub_inserted = true
            return
          end

          super
        end
      end
      private_constant :SyncActionsVisitor

      # Shared installation logic for compiled host adapters.
      module Base
        def install(gem_src:, app_dir:)
          ir_dir = File.join(app_dir, "lib/instant_record")
          File.binwrite(File.join(ir_dir, "host.rb"), host_source)
          File.binwrite(File.join(ir_dir, "runtime_scoped.rb"), RUNTIME_SCOPED_SEAM)
          File.binwrite(File.join(ir_dir, "native.rb"), NATIVE_SEAM)

          sig_dir = File.join(app_dir, "sig/instant_record")
          FileUtils.mkdir_p(sig_dir) unless File.directory?(sig_dir)
          signatures.each do |rbs|
            File.binwrite(
              File.join(sig_dir, rbs),
              File.binread(File.join(gem_src, "sig/instant_record", rbs))
            )
          end

          adapt_compiled_mutate_signatures(app_dir)
          adapt_sync_actions(app_dir)
        end

        def signatures = %w[native.rbs inertia.rbs]

        def adapt_compiled_mutate_source(source)
          return source if source.encoding.ascii_compatible? && !source.include?("mutate")

          parsed = Prism.parse(source)
          return source unless parsed.success?

          edits = []
          MutateDefVisitor.new(self, source, edits).visit(parsed.value)
          return source if edits.empty?

          AstLowerer.apply_edits(source, edits)
        end

        def adapt_sync_actions_source(source, rel: "lib/instant_record/sync_actions.rb")
          parsed = Prism.parse(source)
          raise BuildError, "Cannot parse #{rel}" unless parsed.success?

          edits = []
          SyncActionsVisitor.new(self, source, edits).visit(parsed.value)
          return source if edits.empty?

          adapted = AstLowerer.apply_edits(source, edits)
          raise BuildError, "Invalid Ruby after adapting sync_actions.rb" unless Prism.parse_success?(adapted)

          adapted
        end

        private

        # Spinel does not support `**kwargs` splats; rewrite `InstantRecord.mutate`
        # via Prism AST to accept a plain `args = {}` hash.
        def adapt_compiled_mutate_signatures(app_dir)
          path = File.join(app_dir, "lib/instant_record.rb")
          return unless File.file?(path)

          source = File.read(path, encoding: Encoding::UTF_8)
          adapted = adapt_compiled_mutate_source(source)
          File.binwrite(path, adapted) unless adapted.equal?(source)
        end

        # Strip CRuby-only server frame, ActiveJob guard, and dynamic dispatch from
        # `lib/instant_record/sync_actions.rb` using Prism's AST; EntryBuilder emits
        # the static `case` dispatcher in `main_*.rb`.
        def adapt_sync_actions(app_dir)
          rel = "lib/instant_record/sync_actions.rb"
          path = File.join(app_dir, rel)
          return unless File.file?(path)

          source = File.read(path, encoding: Encoding::UTF_8)
          adapted = adapt_sync_actions_source(source, rel: rel)
          File.binwrite(path, adapted) unless adapted.equal?(source)
        end

        def sync_mutate_edits(source, node)
          signature_end = node.rparen_loc || node.parameters.location
          signature = AstLowerer::Edit.new(
            start_offset: node.location.start_offset,
            end_offset: signature_end.end_offset,
            replacement: "def mutate(mutator_name, args = {}, mutation_id: nil)"
          )
          assignments = Array(node.body&.body).grep(Prism::LocalVariableWriteNode).filter_map do |write|
            case write.name
            when :merged then delete_lines_edit(source, write)
            when :normalized then replace_node_edit(write, "normalized = normalize_args(args)")
            end
          end
          [signature, *assignments]
        end

        def sync_actions_stub_edit(source, node)
          indent = AstLowerer.leading_indent(source, node.location.start_offset)
          replace_lines_edit(source, node, AstLowerer.reindent_block(SPINEL_SYNC_ACTIONS_STUB, target_indent: indent))
        end

        def replace_def_edit(source, node, signature:, body:)
          indent = AstLowerer.leading_indent(source, node.location.start_offset)
          replace_node_edit(node, "def #{signature}\n#{indent}  #{body}\n#{indent}end")
        end

        def replace_node_edit(node, replacement)
          AstLowerer::Edit.new(
            start_offset: node.location.start_offset,
            end_offset: node.location.end_offset,
            replacement: replacement
          )
        end

        def replace_lines_edit(source, node, replacement)
          AstLowerer::Edit.new(
            start_offset: AstLowerer.line_start_of(source, node.location.start_offset),
            end_offset: AstLowerer.line_end_after(source, node.location.end_offset),
            replacement: replacement
          )
        end

        def delete_lines_edit(source, node) = replace_lines_edit(source, node, "")

        def build_host_source(adapter_comment:, blank_id_comment:, blank_id_body:, read_channel_body:, write_channel_body:)
          indented_comment = blank_id_comment.lines(chomp: true).map { |line| "    #{line}" }.join("\n")
          <<~RUBY.freeze
            module InstantRecord
              #{adapter_comment}
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

            #{indented_comment}
                def blank_id?(id)
                  #{blank_id_body}
                end

                def read_channel(name)
                  #{read_channel_body}
                end

                def write_channel(name, body)
                  #{write_channel_body}
                end
              end
            end
          RUBY
        end
      end

      # Browser wasm32-wasi reactor host: communicates with the dedicated worker
      # through virtual `/host/*` files.
      module Wasm
        extend Base

        HOST_SOURCE = build_host_source(
          adapter_comment: "# Compiled wasm32-wasi host adapter (see Compiler::HostAdapters::Wasm).",
          blank_id_comment: %(# Compiled models initialize a new record's id to "", not nil.),
          blank_id_body: "id.blank?",
          read_channel_body: 'File.read("/host/#{name}")',
          write_channel_body: 'File.write("/host/#{name}", body)'
        )

        module_function

        def target = :wasm
        def host_source = HOST_SOURCE
      end

      # Native static-library host (macOS host binary / iOS simulator / iPhone):
      # communicates through NativeHost FFI calls (`native_shim.c`).
      module Native
        extend Base

        HOST_SOURCE = build_host_source(
          adapter_comment: "# Compiled native host adapter (see Compiler::HostAdapters::Native).",
          blank_id_comment: <<~'COMMENT',
            # Compiled models initialize a new record's id to "", not nil. EntryBuilder
            # puts this source where Roundhouse's output was, and Spinel's String has
            # no `blank?` of its own.
          COMMENT
          blank_id_body: "id.to_s.empty?",
          read_channel_body: "NativeHost.ir_host_take(name)",
          write_channel_body: "NativeHost.ir_host_give(name, body)"
        )

        module_function

        def target = :native
        def host_source = HOST_SOURCE
        def signatures = %w[native.rbs inertia.rbs native_host.rbs]
      end

      # Demo-specific seams isolated from GemVendor core vendoring. Ruby edits use
      # Prism AST rewrites rather than literal string substitution.
      module Demo
        SERVER_URL_RECEIVERS = %w[InstantRecord ::InstantRecord].freeze
        private_constant :SERVER_URL_RECEIVERS

        SERVER_URL_ROUTES = {
          slack_reset_path: "/slack/reset",
          auth_session_path: "/auth/session",
          auth_session_sign_out_path: "/auth/session/sign_out"
        }.freeze

        class ServerUrlVisitor < FastVisitor
          def initialize(edits)
            @edits = edits
          end

          def visit_call_node(node)
            if node.name == :server_url &&
               SERVER_URL_RECEIVERS.include?(AstLowerer.constant_name(node.receiver))
              args = node.arguments&.arguments
              if args&.length == 1
                resolved = Demo.resolve_demo_route(args.first)
                if resolved
                  @edits << AstLowerer::Edit.new(
                    start_offset: node.location.start_offset,
                    end_offset: node.location.end_offset,
                    replacement: %("#{resolved}?#{InstantRecord::NETWORK_MARKER}")
                  )
                end
              end
            end

            super
          end
        end
        private_constant :ServerUrlVisitor

        class ThreadParentTernaryVisitor < FastVisitor
          def initialize(edits)
            @edits = edits
          end

          def visit_if_node(node)
            if Demo.thread_parent_ternary?(node)
              replies = node.statements&.body&.first
              fallback = node.subsequent&.statements&.body&.first
              if replies.is_a?(Prism::CallNode) && replies.name != :to_a &&
                 fallback.is_a?(Prism::ArrayNode) && fallback.elements.empty?
                end_off = replies.location.end_offset
                @edits << AstLowerer::Edit.new(start_offset: end_off, end_offset: end_off, replacement: ".to_a")
              end
            end

            super
          end
        end
        private_constant :ThreadParentTernaryVisitor

        module_function

        def apply(app_dir:)
          apply_staged(app_dir: app_dir, defer_ruby_writes: false)
          nil
        end

        # Internal hook for GemVendor to run demo seams while keeping rewritten
        # Ruby files in memory (avoiding write -> re-read -> rewrite round-trips)
        # and returning any `.rb` files seen while walking `app/views`.
        def apply_staged(app_dir:, defer_ruby_writes: true)
          fingerprint_stylesheets(app_dir)
          version_inbox_bundle(app_dir)
          view_rb_files = adapt_demo_views(app_dir, collect_rb_files: defer_ruby_writes)
          modified_ruby = defer_ruby_writes ? {} : nil
          rewrite_server_url_helpers(app_dir, modified_ruby: modified_ruby)
          coerce_slack_thread_replies(app_dir, modified_ruby: modified_ruby)
          [modified_ruby, view_rb_files]
        end

        def fingerprint_stylesheets(app_dir)
          stylesheets_dir = File.join(app_dir, "app/assets/stylesheets")
          return unless File.directory?(stylesheets_dir)

          names = []
          Dir.each_child(stylesheets_dir) do |name|
            next if name.start_with?(".") || !name.end_with?(".css")

            names << name
          end
          names.sort!
          names.each do |name|
            sheet = "#{stylesheets_dir}/#{name}"
            digest = Digest::SHA256.hexdigest(File.binread(sheet))[0, 10]
            stem = name.byteslice(0, name.bytesize - 4)
            File.rename(sheet, "#{stylesheets_dir}/#{stem}-#{digest}.css")
          end
        end

        def version_inbox_bundle(app_dir)
          bundle = File.join(app_dir, "app/assets/builds/inbox.js")
          view = File.join(app_dir, "app/views/email/mailboxes/index.html.erb")
          return unless File.file?(bundle) && File.file?(view)

          digest = Digest::SHA256.hexdigest(File.binread(bundle))[0, 10]
          source = File.read(view)
          target = '<%= asset_path("inbox.js") %>'
          replacement = "/assets/inbox.js?v=#{digest}"
          if source.include?(target)
            File.binwrite(view, source.sub(target) { replacement })
          elsif !source.include?(replacement)
            raise BuildError, "demo seam did not apply: app/views/email/mailboxes/index.html.erb"
          end
        end

        def adapt_demo_views(app_dir, collect_rb_files: false)
          layout_path = File.join(app_dir, "app/views/layouts/application.html.erb")
          if File.file?(layout_path)
            source = File.read(layout_path)
            source.gsub!('<span class="micro-label">Local-first Rails demos —', '<span class="micro-label"><a href="/">All demos</a> ·')
            source.gsub!('<%= source_path(page: controller_path, view: action_name) %>', "/source")
            source.gsub!("Read live out of app.wasm — not a snippet", "View the source for this build")
            source.gsub!('demo-<%= controller_path.split("/").first %>', "demo-<%= content_for(:demo_scope) %>")
            source.gsub!('<% demo = controller_path.split("/").first %>', "<% demo = content_for(:demo_scope).to_s %>")
            File.binwrite(layout_path, source)
          end

          views_dir = File.join(app_dir, "app/views")
          return nil unless File.directory?(views_dir)

          rb_files = collect_rb_files && !File.symlink?(views_dir) ? {} : nil
          walk_demo_views(views_dir, nil, nil, "app/views/", rb_files)
          rb_files
        end

        def walk_demo_views(dir, top_scope, parent_name, rel_prefix, rb_files)
          Dir.each_child(dir) do |entry|
            next if entry.start_with?(".")

            full = "#{dir}/#{entry}"
            st = File.lstat(full)
            if st.directory?
              walk_demo_views(full, top_scope || entry, entry, "#{rel_prefix}#{entry}/", rb_files)
            elsif entry.end_with?(".html.erb") && !entry.start_with?("_") && parent_name != "layouts" && (st.file? || (st.symlink? && File.file?(full)))
              scope = top_scope || entry
              File.binwrite(full, "<% content_for(:demo_scope, \"#{scope}\") %>\n".b << File.binread(full))
            elsif rb_files && entry.end_with?(".rb") && (st.file? || (st.symlink? && File.file?(full)))
              rb_files["#{rel_prefix}#{entry}"] = File.binread(full)
            end
          end
        end
        private_class_method :walk_demo_views

        # Rewrites `InstantRecord.server_url(...)` calls in demo helpers into static
        # network-marked path literals using Prism's AST.
        def rewrite_server_url_helpers(app_dir, modified_ruby: nil)
          %w[app/helpers/slack_helper.rb app/helpers/auth_helper.rb].each do |rel|
            rewrite_demo_ast_with_visitor(
              app_dir, rel, ServerUrlVisitor,
              missing_reason: "no InstantRecord.server_url calls rewritten",
              modified_ruby: modified_ruby
            )
          end
        end

        # Compiled code needs a single array type across both branches of the
        # `@thread_parent ? <relation> : []` ternary.
        def coerce_slack_thread_replies(app_dir, modified_ruby: nil)
          rewrite_demo_ast_with_visitor(
            app_dir, "app/controllers/slack/channels_controller.rb",
            ThreadParentTernaryVisitor,
            missing_reason: "@thread_parent ternary not found",
            modified_ruby: modified_ruby
          )
        end

        def rewrite_demo_ast_with_visitor(app_dir, rel, visitor_class, missing_reason:, modified_ruby: nil)
          path = File.join(app_dir, rel)
          return unless File.file?(path)

          source = File.read(path, encoding: Encoding::UTF_8)
          parsed = Prism.parse(source)
          raise BuildError, "Cannot parse #{rel}" unless parsed.success?

          edits = []
          visitor_class.new(edits).visit(parsed.value)
          raise BuildError, "demo seam did not apply: #{rel}: #{missing_reason}" if edits.empty?

          rewritten = AstLowerer.apply_edits(source, edits)
          if modified_ruby
            modified_ruby[rel] = rewritten
          else
            File.binwrite(path, rewritten)
          end
        end
        private_class_method :rewrite_demo_ast_with_visitor

        # A ternary is an IfNode without a keyword; each branch is one statement.
        def thread_parent_ternary?(node)
          node.is_a?(Prism::IfNode) && node.if_keyword_loc.nil? &&
            node.predicate.is_a?(Prism::InstanceVariableReadNode) && node.predicate.name == :@thread_parent
        end

        def resolve_demo_route(arg)
          case arg
          when Prism::StringNode
            arg.unescaped
          when Prism::CallNode
            SERVER_URL_ROUTES[arg.name] if arg.receiver.nil? && arg.arguments.nil?
          end
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

      def walk_ast(node, &block)
        return if node.nil?

        return if yield(node) == :skip

        node.compact_child_nodes.each { |child| walk_ast(child, &block) }
      end
    end
  end
end
