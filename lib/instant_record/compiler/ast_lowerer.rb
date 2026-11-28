require "prism"
require_relative "runner"

module InstantRecord
  class Compiler
    # Prism AST lowering pass for ahead-of-time compilation. Replaces fragile
    # indentation regexes and literal string patches with syntax-aware byte-range
    # rewrites:
    #
    # - Strips `server_only` blocks and unwraps `browser_only` / `client_only`
    #   blocks (both `do ... end` and `{ ... }`, including nested blocks).
    # - Folds compile-time `InstantRecord.browser?` checks, boolean combinations,
    #   ternaries, and `if`/`unless`/`elsif` branches (statement & modifier forms).
    # - Rewrites `include InstantRecord::Syncable` -> `include Syncable` in models.
    # - Unnests `module InstantRecord; module Syncable ... end; end` cleanly via AST.
    class AstLowerer
      Edit = Struct.new(:start_offset, :end_offset, :replacement, keyword_init: true)

      CLIENT_BLOCK_METHODS = %i[browser_only client_only].freeze
      SCOPED_BLOCK_METHODS = %i[server_only browser_only client_only].freeze

      # Byte-level token boundary regexes (ASCII-8BIT /n) used only after fast
      # String#include? checks match. Every byte class is derived from Ruby's
      # lexer rules so valid lowerable constructs cannot be skipped.
      SCOPED_BLOCK_RE = /(?<![A-Za-z0-9_\x80-\xFF])(?:server|browser|client)_only(?:[ \t\r\f\v]|\\\r?\n)*(?:\{|do(?![A-Za-z0-9_\x80-\xFF])|\((?=[ \t\r\n\f\v#)=\\]))/n
      BROWSER_CALL_RE = /(?:\.|::)(?:[ \t\r\n\f\v\\]|#[^\n]*\n)*browser\?/n
      INCLUDE_IR_RE = /(?<![A-Za-z0-9_.\x80-\xFF])include(?=[ \t\r\f\v\\(])(?:[ \t\r\n\f\v\\(:]|#[^\n]*\n)*InstantRecord(?![A-Za-z0-9_\x80-\xFF])/n
      INCLUDE_CALL_RE = /(?<![A-Za-z0-9_.\x80-\xFF])include(?![A-Za-z0-9_?!=\x80-\xFF])/n
      HEREDOC_START_RE = /<<[~\-'"`A-Za-z0-9_\x80-\xFF\\]/n

      LEADING_INDENT_RE = /\A[ \t]*/
      BLANK_LINE_UTF8_RE = /\A[ \t\r\f\v\0]*\z/
      ONLY_WHITESPACE_RE = /\A[ \t]*\z/n
      TAIL_WHITESPACE_OR_COMMENT_RE = /\A[ \t]*(?:#[^\n]*)?\r?\n?\z/n
      FIRST_NON_NL_RE = /[^\n]/
      FIRST_NON_SP_RE = /[^ ]/
      NEWLINE_B = "\n".b.freeze

      MAX_CACHED_INDENT = 32
      SHALLOW_LINE_RES = Array.new(MAX_CACHED_INDENT + 1) { |indent| indent > 0 ? /\n {0,#{indent - 1}}[^ \n]/ : nil }.freeze
      SPACE_PREFIXES = Array.new(MAX_CACHED_INDENT + 1) { |indent| (" " * indent).freeze }.freeze

      def self.lower(source, runtime: :client, rewrite_syncable_include: false)
        instance_for(runtime: runtime, rewrite_syncable_include: rewrite_syncable_include).lower(source)
      end

      def self.instance_for(runtime:, rewrite_syncable_include:)
        case runtime
        when :client
          rewrite_syncable_include ? CLIENT_REWRITE : CLIENT_PLAIN
        when :server
          rewrite_syncable_include ? SERVER_REWRITE : SERVER_PLAIN
        else
          raise ArgumentError, "Unknown lowering runtime: #{runtime.inspect}"
        end
      end
      private_class_method :instance_for

      def self.lower_file(path, runtime: :client, rewrite_syncable_include: false)
        source = File.read(path, encoding: Encoding::UTF_8)
        lowered = lower(source, runtime: runtime, rewrite_syncable_include: rewrite_syncable_include)
        if !lowered.equal?(source) && lowered != source
          File.write(path, lowered)
          true
        else
          false
        end
      end

      # Unnests `module InstantRecord; module Syncable ... end; end` to a top-level
      # `module Syncable` concern file using Prism's AST rather than line indexing.
      def self.unnest_syncable(source)
        parsed = Prism.parse(source)
        unless parsed.success?
          raise BuildError, "Cannot parse syncable.rb: #{parsed.errors.map(&:message).join('; ')}"
        end

        outer = Array(parsed.value.statements&.body).find do |node|
          node.is_a?(Prism::ModuleNode) && constant_name(node.constant_path) == "InstantRecord"
        end
        unless outer
          raise BuildError, "Unexpected structure in syncable.rb: missing module InstantRecord"
        end

        inner_nodes = Array(outer.body&.body)
        syncable = inner_nodes.find do |node|
          node.is_a?(Prism::ModuleNode) && constant_name(node.constant_path) == "Syncable"
        end
        unless syncable
          raise BuildError, "Unexpected structure in syncable.rb: missing module Syncable inside InstantRecord"
        end

        bytes = binary_view(source)
        open_end = line_end_after(bytes, outer.constant_path.location.end_offset)
        close_start = line_start_of(bytes, outer.end_keyword_loc.start_offset)
        inner_raw = byteslice(source, open_end, close_start - open_end)
        dedented = reindent_block(inner_raw, target_indent: "")

        outer_start = line_start_of(bytes, outer.location.start_offset)
        outer_end = line_end_after(bytes, outer.location.end_offset)

        apply_edits(source, [Edit.new(start_offset: outer_start, end_offset: outer_end, replacement: dedented)], source_bytes: bytes)
      end

      # Applies non-overlapping byte-offset edits to a UTF-8 Ruby source string.
      def self.apply_edits(source, edits, source_bytes: nil)
        return source if edits.empty?

        sorted = edits.length > 1 ? edits.sort_by { |e| [e.start_offset, e.end_offset] } : edits
        prev_end = 0
        sorted.each do |edit|
          if edit.start_offset < prev_end
            raise BuildError, "Overlapping AST edits at byte offset #{edit.start_offset} < #{prev_end}"
          end
          prev_end = edit.end_offset
        end

        bytes = source_bytes || binary_view(source)
        out = String.new(capacity: bytes.bytesize, encoding: Encoding::BINARY)
        cursor = 0
        sorted.each do |edit|
          out << bytes.byteslice(cursor, edit.start_offset - cursor) if edit.start_offset > cursor
          repl = edit.replacement
          out << binary_view(repl) unless repl.empty?
          cursor = edit.end_offset
        end
        out << bytes.byteslice(cursor, bytes.bytesize - cursor) if cursor < bytes.bytesize
        out.force_encoding(source.encoding)
      end

      def self.constant_name(node)
        case node
        when Prism::ConstantReadNode
          node.name.to_s
        when Prism::ConstantPathNode
          parent = node.parent ? constant_name(node.parent) : ""
          return nil if parent.nil?

          parent.empty? ? "::#{node.name}" : "#{parent}::#{node.name}"
        end
      end

      def self.byteslice(str, start_offset, length)
        return "" if length <= 0

        str.byteslice(start_offset, length)
      end

      def self.binary_view(str)
        str.encoding == Encoding::BINARY ? str : str.b
      end

      def self.line_start_of(source, offset)
        return 0 if offset <= 0

        bytes = binary_view(source)
        idx = bytes.rindex(NEWLINE_B, offset - 1)
        idx ? idx + 1 : 0
      end

      def self.line_end_after(source, offset)
        bytes = binary_view(source)
        idx = bytes.index(NEWLINE_B, offset)
        idx ? idx + 1 : bytes.bytesize
      end

      def self.leading_indent(source, offset)
        line_start = line_start_of(source, offset)
        prefix = byteslice(source, line_start, offset - line_start)
        prefix[LEADING_INDENT_RE]
      end

      def self.only_whitespace_before_on_line?(source, offset)
        bytes = binary_view(source)
        line_start = line_start_of(bytes, offset)
        len = offset - line_start
        return true if len <= 0

        bytes.byteslice(line_start, len).match?(ONLY_WHITESPACE_RE)
      end

      def self.only_whitespace_or_comment_after_on_line?(source, offset)
        bytes = binary_view(source)
        line_end = line_end_after(bytes, offset)
        len = line_end - offset
        return true if len <= 0

        bytes.byteslice(offset, len).match?(TAIL_WHITESPACE_OR_COMMENT_RE)
      end

      def self.reindent_block(raw, target_indent:)
        return "" if raw.nil? || raw.empty?

        # Fast path for clean LF space-indented blocks without whitespace-only blank lines.
        # Uses literal String#gsub in C rather than splitting/rejoining every line.
        if raw.encoding.ascii_compatible? && raw.valid_encoding? &&
           !target_indent.include?("\\") &&
           !raw.include?("\r") && !raw.include?("\t") && !raw.include?("\f") &&
           !raw.include?("\v") && !raw.include?("\0") &&
           !raw.include?(" \n") && !raw.end_with?(" ")
          first_non_nl = raw.byteindex(FIRST_NON_NL_RE)
          return "" unless first_non_nl

          first_non_sp = raw.byteindex(FIRST_NON_SP_RE, first_non_nl)
          return "" unless first_non_sp

          indent = first_non_sp - first_non_nl
          if indent > 0
            shallow_re = indent <= MAX_CACHED_INDENT ? SHALLOW_LINE_RES[indent] : /\n {0,#{indent - 1}}[^ \n]/
            unless raw.match?(shallow_re)
              prefix = indent <= MAX_CACHED_INDENT ? SPACE_PREFIXES[indent] : (" " * indent)
              out = raw.gsub("\n#{prefix}", "\n#{target_indent}")
              if out.start_with?(prefix)
                rest = out.byteslice(indent, out.bytesize - indent)
                out = target_indent.empty? ? rest : "#{target_indent}#{rest}"
              end
              return out
            end
          end
        end

        reindent_block_general(raw, target_indent: target_indent)
      end

      def self.reindent_block_general(raw, target_indent:)
        lines = raw.split("\n", -1)
        trailing_empty = lines.last.empty?
        lines.pop if trailing_empty

        min_indent = nil
        valid_enc = raw.encoding.ascii_compatible? && raw.valid_encoding?
        n = lines.length
        i = 0
        while i < n
          line = lines[i]
          if line.empty?
            # already blank
          elsif (valid_enc ? BLANK_LINE_UTF8_RE.match?(line) : line.strip.empty?)
            lines[i] = ""
          else
            j = 0
            while (b = line.getbyte(j)) == 32 || b == 9
              j += 1
            end
            min_indent = j if min_indent.nil? || j < min_indent
          end
          i += 1
        end
        return "" if min_indent.nil?

        empty_target = target_indent.empty?
        if min_indent > 0 || !empty_target
          i = 0
          while i < n
            line = lines[i]
            unless line.empty?
              if empty_target
                line.slice!(0, min_indent)
              elsif min_indent == 0
                lines[i] = "#{target_indent}#{line}"
              else
                lines[i] = "#{target_indent}#{line.byteslice(min_indent, line.bytesize - min_indent)}"
              end
            end
            i += 1
          end
        end

        result = lines.join("\n")
        trailing_empty ? "#{result}\n" : result
      end
      private_class_method :reindent_block_general

      def initialize(runtime: :client, rewrite_syncable_include: false)
        unless %i[client server].include?(runtime)
          raise ArgumentError, "Unknown lowering runtime: #{runtime.inspect}"
        end

        @runtime = runtime
        @is_client = runtime == :client
        @rewrite_syncable_include = !!rewrite_syncable_include
      end

      def lower(source)
        has_browser = true
        has_scoped = true
        has_syncable = @rewrite_syncable_include
        source_bytes = nil

        if source.encoding.ascii_compatible?
          has_ir = source.include?("InstantRecord")
          has_only = source.include?("_only")
          return source unless has_ir || has_only

          has_browser = false
          has_scoped = false
          has_syncable = false

          if has_ir
            if source.include?("browser?")
              source_bytes = self.class.binary_view(source)
              has_browser = source_bytes.include?("=begin") || BROWSER_CALL_RE.match?(source_bytes)
            end

            if @rewrite_syncable_include && source.include?("Syncable") && source.include?("include")
              source_bytes ||= self.class.binary_view(source)
              has_syncable = source_bytes.include?("=begin") ? INCLUDE_CALL_RE.match?(source_bytes) : INCLUDE_IR_RE.match?(source_bytes)
            end
          end

          if has_only
            source_bytes ||= self.class.binary_view(source)
            has_scoped = source_bytes.include?("=begin") || SCOPED_BLOCK_RE.match?(source_bytes)
          end

          return source unless has_browser || has_scoped || has_syncable
        end

        parsed = Prism.parse(source)
        return source unless parsed.success?

        # When there are no heredocs, every Prism node's children lie strictly
        # inside [node.location.start_offset, node.location.end_offset), so we
        # can skip large subtrees (methods, classes, blocks) containing no
        # candidate keyword offset.
        candidate_offsets = nil
        if source_bytes && source_bytes.bytesize >= 1024 && !HEREDOC_START_RE.match?(source_bytes)
          candidate_offsets = collect_candidate_offsets(
            source_bytes,
            need_browser: has_browser,
            need_syncable: has_syncable,
            need_only: has_scoped
          )
        end

        edits = []
        collector = Collector.new(
          self,
          source,
          edits,
          is_client: @is_client,
          has_browser: has_browser,
          has_scoped: has_scoped,
          has_syncable: has_syncable,
          source_bytes: source_bytes,
          candidate_offsets: candidate_offsets
        )
        collector.visit(parsed.value)
        return source if edits.empty?

        result = self.class.apply_edits(source, edits, source_bytes: collector.source_bytes)
        unless Prism.parse_success?(result)
          verify = Prism.parse(result)
          raise BuildError, "AST lowering produced invalid Ruby: #{verify.errors.map(&:message).join('; ')}"
        end
        result
      end

      private

      def collect_candidate_offsets(bytes, need_browser:, need_syncable:, need_only:)
        offsets = []
        kinds = 0
        if need_browser
          kinds += 1
          pos = 0
          while (idx = bytes.index("browser?".b, pos))
            offsets << idx
            pos = idx + 8
          end
        end
        if need_syncable
          kinds += 1
          pos = 0
          while (idx = bytes.index("Syncable".b, pos))
            offsets << idx
            pos = idx + 8
          end
        end
        if need_only
          kinds += 1
          pos = 0
          while (idx = bytes.index("_only".b, pos))
            offsets << idx
            pos = idx + 5
          end
        end
        offsets.sort! if kinds > 1 && offsets.length > 1
        offsets
      end

      class Collector < Prism::Visitor
        attr_reader :source_bytes

        def initialize(lowerer, source, edits, is_client:, has_browser:, has_scoped:, has_syncable:, source_bytes:, candidate_offsets:)
          @lowerer = lowerer
          @source = source
          @edits = edits
          @is_client = is_client
          @has_browser = has_browser
          @has_scoped = has_scoped
          @has_syncable = has_syncable
          @source_bytes = source_bytes
          @candidate_offsets = candidate_offsets
          if candidate_offsets && !candidate_offsets.empty?
            @cand_min = candidate_offsets[0]
            @cand_max = candidate_offsets[-1]
            @cand_single = candidate_offsets.length == 1
          else
            @candidate_offsets = nil
          end
        end

        # Leaf nodes with zero children: skip Prism::Visitor's each_child_node call.
        def visit_local_variable_read_node(_); end
        def visit_symbol_node(_); end
        def visit_string_node(_); end
        def visit_integer_node(_); end
        def visit_constant_read_node(_); end
        def visit_instance_variable_read_node(_); end
        def visit_self_node(_); end
        def visit_nil_node(_); end
        def visit_true_node(_); end
        def visit_false_node(_); end
        def visit_required_parameter_node(_); end
        def visit_local_variable_target_node(_); end
        def visit_instance_variable_target_node(_); end
        def visit_constant_target_node(_); end
        def visit_float_node(_); end
        def visit_regular_expression_node(_); end
        def visit_global_variable_read_node(_); end
        def visit_class_variable_read_node(_); end
        def visit_required_keyword_parameter_node(_); end
        def visit_rest_parameter_node(_); end
        def visit_keyword_rest_parameter_node(_); end
        def visit_block_parameter_node(_); end
        def visit_block_local_variable_node(_); end

        # Hot container nodes: traverse fields directly and prune ranges with no candidates.
        def visit_program_node(node)
          node.statements.accept(self)
        end

        def visit_statements_node(node)
          if @candidate_offsets
            loc = node.location
            return unless has_candidate_in?(loc.start_offset, loc.end_offset)
          end

          node.body.each do |stmt|
            case stmt
            when Prism::CallNode
              visit_call_node(stmt, true)
            when Prism::IfNode
              visit_if_node(stmt, true)
            when Prism::UnlessNode
              visit_unless_node(stmt, true)
            else
              stmt.accept(self)
            end
          end
        end

        def visit_def_node(node)
          if @candidate_offsets
            loc = node.location
            return unless has_candidate_in?(loc.start_offset, loc.end_offset)
          end

          node.receiver&.accept(self)
          node.parameters&.accept(self)
          visit_value_returning_body(node.body)
        end

        def visit_block_node(node)
          if @candidate_offsets
            loc = node.location
            return unless has_candidate_in?(loc.start_offset, loc.end_offset)
          end

          node.parameters&.accept(self)
          visit_value_returning_body(node.body)
        end

        def visit_lambda_node(node)
          if @candidate_offsets
            loc = node.location
            return unless has_candidate_in?(loc.start_offset, loc.end_offset)
          end

          node.parameters&.accept(self)
          visit_value_returning_body(node.body)
        end

        def visit_parentheses_node(node)
          if @candidate_offsets
            loc = node.location
            return unless has_candidate_in?(loc.start_offset, loc.end_offset)
          end

          visit_value_returning_body(node.body)
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

        def visit_class_node(node)
          if @candidate_offsets
            loc = node.location
            return unless has_candidate_in?(loc.start_offset, loc.end_offset)
          end

          node.constant_path.accept(self)
          node.superclass&.accept(self)
          node.body&.accept(self)
        end

        def visit_module_node(node)
          if @candidate_offsets
            loc = node.location
            return unless has_candidate_in?(loc.start_offset, loc.end_offset)
          end

          node.constant_path.accept(self)
          node.body&.accept(self)
        end

        def visit_begin_node(node)
          if @candidate_offsets
            loc = node.location
            return unless has_candidate_in?(loc.start_offset, loc.end_offset)
          end

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

        def visit_return_node(node)
          node.arguments&.accept(self)
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

        # Target nodes that may produce edits (the walk does not descend below an edit).
        def visit_call_node(node, removable = false)
          if @candidate_offsets
            loc = node.location
            return unless has_candidate_in?(loc.start_offset, loc.end_offset)
          end

          case node.name
          when :server_only, :browser_only, :client_only
            if @has_scoped &&
               (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)) &&
               node.arguments.nil? &&
               node.block.is_a?(Prism::BlockNode)
              keep = @is_client ? (node.name != :server_only) : (node.name == :server_only)
              @edits << (keep ? unwrap_block_edit(node, removable) : remove_node_edit(node, removable))
              return
            end
          when :include
            if @has_syncable && node.receiver.nil? && node.block.nil?
              args = node.arguments&.arguments
              if args && args.length == 1
                name = AstLowerer.constant_name(args[0])
                if name == "InstantRecord::Syncable" || name == "::InstantRecord::Syncable"
                  @edits << replace_node_edit(args[0], "Syncable")
                  return
                end
              end
            end
          when :browser?
            if @has_browser && node.arguments.nil? && node.block.nil?
              recv = AstLowerer.constant_name(node.receiver)
              if recv == "InstantRecord" || recv == "::InstantRecord"
                @edits << replace_node_edit(node, @is_client ? "true" : "false")
                return
              end
            end
          when :!
            if @has_browser && node.arguments.nil? && node.block.nil?
              value = browser_predicate_value(node.receiver)
              unless value.nil?
                @edits << replace_node_edit(node, value ? "false" : "true")
                return
              end
            end
          end

          node.receiver&.accept(self)
          node.arguments&.accept(self)
          node.block&.accept(self)
        end

        def visit_if_node(node, removable = false)
          if @candidate_offsets
            loc = node.location
            return unless has_candidate_in?(loc.start_offset, loc.end_offset)
          end

          if @has_browser
            value = browser_predicate_value(node.predicate)
            unless value.nil?
              kw = node.if_keyword_loc
              if kw.nil?
                chosen = value ? node.statements : node.subsequent&.statements
                @edits << replace_node_edit(node, chosen ? lower_node(chosen) : "nil")
              elsif kw.length == 5 # "elsif"
                @edits << elsif_edit_for(node, value)
              else
                @edits << branch_edit(node, taken: value, otherwise: node.subsequent, removable: removable)
              end
              return
            end
          end

          node.predicate.accept(self)
          node.statements&.accept(self)
          node.subsequent&.accept(self)
        end

        def visit_unless_node(node, removable = false)
          if @candidate_offsets
            loc = node.location
            return unless has_candidate_in?(loc.start_offset, loc.end_offset)
          end

          if @has_browser
            value = browser_predicate_value(node.predicate)
            unless value.nil?
              @edits << branch_edit(node, taken: !value, otherwise: node.else_clause, removable: removable)
              return
            end
          end

          node.predicate.accept(self)
          node.statements&.accept(self)
          node.else_clause&.accept(self)
        end

        def visit_and_node(node)
          if @has_browser
            left = browser_predicate_value(node.left)
            unless left.nil?
              @edits << replace_node_edit(node, left ? lower_node(node.right) : "false")
              return
            end
          end

          node.left.accept(self)
          node.right.accept(self)
        end

        def visit_or_node(node)
          if @has_browser
            left = browser_predicate_value(node.left)
            unless left.nil?
              @edits << replace_node_edit(node, left ? "true" : lower_node(node.right))
              return
            end
          end

          node.left.accept(self)
          node.right.accept(self)
        end

        private

        def has_candidate_in?(start_off, end_off)
          return false if end_off <= @cand_min || start_off > @cand_max
          return true if @cand_single

          offsets = @candidate_offsets
          lo = 0
          hi = offsets.length - 1
          while lo <= hi
            mid = (lo + hi) >> 1
            off = offsets[mid]
            if off < start_off
              lo = mid + 1
            elsif off >= end_off
              hi = mid - 1
            else
              return true
            end
          end
          false
        end

        def visit_value_returning_body(body)
          return unless body

          if body.is_a?(Prism::StatementsNode)
            stmts = body.body
            len = stmts.length
            if len > 1
              last = len - 1
              i = 0
              while i < last
                stmt = stmts[i]
                case stmt
                when Prism::CallNode
                  visit_call_node(stmt, true)
                when Prism::IfNode
                  visit_if_node(stmt, true)
                when Prism::UnlessNode
                  visit_unless_node(stmt, true)
                else
                  stmt.accept(self)
                end
                i += 1
              end
              stmts[last].accept(self)
            elsif len == 1
              stmt = stmts[0]
              case stmt
              when Prism::CallNode
                visit_call_node(stmt, true)
              when Prism::IfNode
                visit_if_node(stmt, true)
              when Prism::UnlessNode
                visit_unless_node(stmt, true)
              else
                stmt.accept(self)
              end
            end
          else
            body.accept(self)
          end
        end

        def bytes
          @source_bytes ||= AstLowerer.binary_view(@source)
        end

        # true or false when the runtime decides `node`, nil when it does not.
        def browser_predicate_value(node)
          case node
          when Prism::ParenthesesNode
            stmts = node.body&.body
            stmts && stmts.length == 1 ? browser_predicate_value(stmts[0]) : nil
          when Prism::CallNode
            return unless node.arguments.nil? && node.block.nil?

            if node.name == :browser?
              recv = AstLowerer.constant_name(node.receiver)
              @is_client if recv == "InstantRecord" || recv == "::InstantRecord"
            elsif node.name == :!
              inner = browser_predicate_value(node.receiver)
              inner.nil? ? nil : !inner
            end
          when Prism::AndNode
            left = browser_predicate_value(node.left)
            left ? browser_predicate_value(node.right) : left
          when Prism::OrNode
            left = browser_predicate_value(node.left)
            left == false ? browser_predicate_value(node.right) : left
          end
        end

        # Lowers an `if` or `unless` whose body is known to run (`taken`) or not.
        # `otherwise` is its `else` or `elsif` clause.
        def branch_edit(node, taken:, otherwise:, removable:)
          # Modifier `stmt if cond` or `stmt unless cond`
          if node.end_keyword_loc.nil?
            return remove_node_edit(node, removable) unless taken

            return replace_node_edit(node, lower_node(node.statements))
          end

          if taken
            keep_branch_edit(
              node, node.statements,
              open_end: predicate_end(node),
              close_start: (otherwise&.location || node.end_keyword_loc).start_offset,
              removable: removable
            )
          elsif otherwise.is_a?(Prism::ElseNode)
            keep_branch_edit(
              node, otherwise.statements,
              open_end: otherwise.else_keyword_loc.end_offset,
              close_start: node.end_keyword_loc.start_offset,
              removable: removable
            )
          elsif otherwise
            # `if false ... elsif cond2 ... end` -> lower `if cond2 ... end`
            replace_node_edit(node, @lowerer.lower("if" + slice(otherwise.if_keyword_loc.end_offset, node.location.end_offset)))
          else
            remove_node_edit(node, removable)
          end
        end

        # An `elsif` sits inside an outer `if` whose predicate was not folded, so its
        # edit reaches to the `end` that closes the whole chain.
        def elsif_edit_for(node, value)
          start = node.location.start_offset
          chain_end = find_elsif_chain_end(node)
          if value
            close_start = node.subsequent&.location&.start_offset || chain_end
            replacement = "else#{lower_slice(predicate_end(node), close_start)}"
            Edit.new(start_offset: start, end_offset: chain_end, replacement: replacement)
          elsif node.subsequent
            replacement = lower_subsequent_clause(slice(node.subsequent.location.start_offset, chain_end))
            Edit.new(start_offset: start, end_offset: chain_end, replacement: replacement)
          else
            # Drop trailing dead `elsif` cleanly up to the closing `end` line
            b = bytes
            start = AstLowerer.line_start_of(b, start) if AstLowerer.only_whitespace_before_on_line?(b, start)
            Edit.new(start_offset: start, end_offset: AstLowerer.line_start_of(b, chain_end), replacement: "")
          end
        end

        def predicate_end(node)
          (node.then_keyword_loc || node.predicate.location).end_offset
        end

        def find_elsif_chain_end(node)
          curr = node
          while curr
            return curr.end_keyword_loc.start_offset if curr.respond_to?(:end_keyword_loc) && curr.end_keyword_loc

            curr = curr.respond_to?(:subsequent) ? curr.subsequent : nil
          end
          node.location.end_offset
        end

        # An `elsif` or `else` does not parse on its own.
        def lower_subsequent_clause(sub_raw)
          wrapper = "if __ir_keep__\n#{sub_raw}end\n"
          lowered = @lowerer.lower(wrapper)
          lowered.delete_prefix("if __ir_keep__\n").delete_suffix("end\n")
        end

        def unwrap_block_edit(call_node, removable)
          block = call_node.block
          return remove_node_edit(call_node, removable) if block.body.nil?

          opening = block.opening_loc
          closing = block.closing_loc
          if opening.start_line != closing.start_line && full_line_node?(call_node)
            b = bytes
            body_start = AstLowerer.line_end_after(b, opening.end_offset)
            body_end = AstLowerer.line_start_of(b, closing.start_offset)
            keep_lines_edit(call_node, body_start, body_end, removable)
          else
            replace_node_edit(call_node, lower_node(block.body))
          end
        end

        def keep_branch_edit(node, statements, open_end:, close_start:, removable:)
          return remove_node_edit(node, removable) if statements.nil?

          if full_line_node?(node)
            b = bytes
            body_start = AstLowerer.line_end_after(b, open_end)
            body_end = AstLowerer.line_start_of(b, close_start)
            return keep_lines_edit(node, body_start, body_end, removable) if body_end > body_start
          end

          replace_node_edit(node, lower_node(statements))
        end

        def keep_lines_edit(node, body_start, body_end, removable)
          b = bytes
          line_start = AstLowerer.line_start_of(b, node.location.start_offset)
          indent = AstLowerer.byteslice(@source, line_start, node.location.start_offset - line_start)[LEADING_INDENT_RE]
          body = AstLowerer.reindent_block(lower_slice(body_start, body_end), target_indent: indent)
          return remove_node_edit(node, removable) if body.empty?

          replace_lines_edit(node, body)
        end

        def remove_node_edit(node, removable)
          if removable && full_line_node?(node)
            replace_lines_edit(node, "")
          else
            replace_node_edit(node, "nil")
          end
        end

        def replace_node_edit(node, replacement)
          Edit.new(start_offset: node.location.start_offset, end_offset: node.location.end_offset, replacement: replacement)
        end

        def replace_lines_edit(node, replacement)
          b = bytes
          Edit.new(
            start_offset: AstLowerer.line_start_of(b, node.location.start_offset),
            end_offset: AstLowerer.line_end_after(b, node.location.end_offset),
            replacement: replacement
          )
        end

        def full_line_node?(node)
          b = bytes
          AstLowerer.only_whitespace_before_on_line?(b, node.location.start_offset) &&
            AstLowerer.only_whitespace_or_comment_after_on_line?(b, node.location.end_offset)
        end

        def lower_node(node)
          lower_slice(node.location.start_offset, node.location.end_offset)
        end

        def lower_slice(start_offset, end_offset)
          @lowerer.lower(slice(start_offset, end_offset))
        end

        def slice(start_offset, end_offset)
          AstLowerer.byteslice(@source, start_offset, end_offset - start_offset)
        end
      end
      private_constant :Collector

      CLIENT_PLAIN = new(runtime: :client, rewrite_syncable_include: false).freeze
      CLIENT_REWRITE = new(runtime: :client, rewrite_syncable_include: true).freeze
      SERVER_PLAIN = new(runtime: :server, rewrite_syncable_include: false).freeze
      SERVER_REWRITE = new(runtime: :server, rewrite_syncable_include: true).freeze
      private_constant :CLIENT_PLAIN, :CLIENT_REWRITE, :SERVER_PLAIN, :SERVER_REWRITE
    end
  end
end
