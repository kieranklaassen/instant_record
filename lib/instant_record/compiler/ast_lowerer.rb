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

      def self.lower(source, runtime: :client, rewrite_syncable_include: false)
        new(runtime: runtime, rewrite_syncable_include: rewrite_syncable_include).lower(source)
      end

      def self.lower_file(path, runtime: :client, rewrite_syncable_include: false)
        source = File.read(path, encoding: Encoding::UTF_8)
        lowered = lower(source, runtime: runtime, rewrite_syncable_include: rewrite_syncable_include)
        if lowered != source
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

        open_end = line_end_after(source, outer.constant_path.location.end_offset)
        close_start = line_start_of(source, outer.end_keyword_loc.start_offset)
        inner_raw = byteslice(source, open_end, close_start - open_end)
        dedented = reindent_block(inner_raw, target_indent: "")

        outer_start = line_start_of(source, outer.location.start_offset)
        outer_end = line_end_after(source, outer.location.end_offset)

        apply_edits(source, [Edit.new(start_offset: outer_start, end_offset: outer_end, replacement: dedented)])
      end

      # Applies non-overlapping byte-offset edits to a UTF-8 Ruby source string.
      def self.apply_edits(source, edits)
        return source if edits.empty?

        sorted = edits.sort_by { |e| [e.start_offset, e.end_offset] }
        prev_end = 0
        sorted.each do |edit|
          if edit.start_offset < prev_end
            raise BuildError, "Overlapping AST edits at byte offset #{edit.start_offset} < #{prev_end}"
          end
          prev_end = edit.end_offset
        end

        bytes = source.b
        out = +"".b
        cursor = 0
        sorted.each do |edit|
          out << bytes.byteslice(cursor, edit.start_offset - cursor) if edit.start_offset > cursor
          out << edit.replacement.b
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

        str.b.byteslice(start_offset, length).force_encoding(str.encoding)
      end

      def self.line_start_of(source, offset)
        bytes = source.b
        idx = bytes.rindex("\n".b, [offset - 1, 0].max)
        offset == 0 || idx.nil? ? 0 : idx + 1
      end

      def self.line_end_after(source, offset)
        bytes = source.b
        idx = bytes.index("\n".b, offset)
        idx ? idx + 1 : bytes.bytesize
      end

      def self.leading_indent(source, offset)
        line_start = line_start_of(source, offset)
        prefix = byteslice(source, line_start, offset - line_start)
        prefix[/\A[ \t]*/]
      end

      def self.only_whitespace_before_on_line?(source, offset)
        line_start = line_start_of(source, offset)
        byteslice(source, line_start, offset - line_start).match?(/\A[ \t]*\z/)
      end

      def self.only_whitespace_or_comment_after_on_line?(source, offset)
        line_end = line_end_after(source, offset)
        tail = byteslice(source, offset, line_end - offset)
        tail.match?(/\A[ \t]*(?:#[^\n]*)?\r?\n?\z/)
      end

      def self.reindent_block(raw, target_indent:)
        return "" if raw.nil? || raw.empty?

        lines = raw.split("\n", -1)
        trailing_empty = lines.last == ""
        lines.pop if trailing_empty

        non_blank = lines.reject { |line| line.strip.empty? }
        return "" if non_blank.empty?

        min_indent = non_blank.map { |line| line[/\A[ \t]*/].length }.min
        reindented = lines.map do |line|
          if line.strip.empty?
            ""
          else
            "#{target_indent}#{line[min_indent..]}"
          end
        end

        result = reindented.join("\n")
        trailing_empty ? "#{result}\n" : result
      end

      def initialize(runtime: :client, rewrite_syncable_include: false)
        unless %i[client server].include?(runtime)
          raise ArgumentError, "Unknown lowering runtime: #{runtime.inspect}"
        end

        @runtime = runtime
        @rewrite_syncable_include = rewrite_syncable_include
      end

      def lower(source)
        parsed = Prism.parse(source)
        return source unless parsed.success?

        edits = collect_edits(source, parsed.value)
        return source if edits.empty?

        result = self.class.apply_edits(source, edits)
        verify = Prism.parse(result)
        unless verify.success?
          raise BuildError, "AST lowering produced invalid Ruby: #{verify.errors.map(&:message).join('; ')}"
        end
        result
      end

      private

      def collect_edits(source, root)
        edits = []
        visit(source, root, edits)
        edits
      end

      # The walk does not go below an edit. A `removable` node may be dropped with its
      # lines; any other leaves `nil`.
      def visit(source, node, edits, removable: false)
        if (edit = edit_for(source, node, removable: removable))
          edits << edit
          return
        end

        node.compact_child_nodes.each do |child|
          if child.is_a?(Prism::StatementsNode)
            visit_statements(source, child, edits, owner: node)
          else
            visit(source, child, edits)
          end
        end
      end

      def visit_statements(source, node, edits, owner:)
        body = node.body
        returned = body.last if body.length > 1 && value_returning_owner?(owner)
        body.each { |stmt| visit(source, stmt, edits, removable: !stmt.equal?(returned)) }
      end

      def value_returning_owner?(node)
        node.is_a?(Prism::DefNode) ||
          node.is_a?(Prism::BlockNode) ||
          node.is_a?(Prism::LambdaNode) ||
          node.is_a?(Prism::ParenthesesNode)
      end

      def edit_for(source, node, removable:)
        case node
        when Prism::CallNode
          call_edit(source, node, removable: removable)
        when Prism::IfNode
          if_edit(source, node, removable: removable)
        when Prism::UnlessNode
          value = browser_predicate_value(node.predicate)
          branch_edit(source, node, taken: !value, otherwise: node.else_clause, removable: removable) unless value.nil?
        when Prism::AndNode
          short_circuit_edit(source, node, stops_at: false)
        when Prism::OrNode
          short_circuit_edit(source, node, stops_at: true)
        end
      end

      def call_edit(source, node, removable:)
        if scoped_block_call?(node)
          if keep_block?(node.name)
            unwrap_block_edit(source, node, removable: removable)
          else
            remove_node_edit(source, node, removable: removable)
          end
        elsif @rewrite_syncable_include && syncable_include_call?(node)
          replace_node_edit(node.arguments.arguments.first, "Syncable")
        else
          value = browser_predicate_value(node)
          replace_node_edit(node, value.to_s) unless value.nil?
        end
      end

      def short_circuit_edit(source, node, stops_at:)
        left = browser_predicate_value(node.left)
        return if left.nil?

        replace_node_edit(node, left == stops_at ? left.to_s : lower_node(source, node.right))
      end

      def if_edit(source, node, removable:)
        return elsif_edit(source, node) if node.if_keyword_loc&.slice == "elsif"

        value = browser_predicate_value(node.predicate)
        return if value.nil?

        # Ternary: `cond ? a : b`
        if node.if_keyword_loc.nil?
          chosen = value ? node.statements : node.subsequent&.statements
          return replace_node_edit(node, chosen ? lower_node(source, chosen) : "nil")
        end

        branch_edit(source, node, taken: value, otherwise: node.subsequent, removable: removable)
      end

      # Lowers an `if` or `unless` whose body is known to run (`taken`) or not.
      # `otherwise` is its `else` or `elsif` clause.
      def branch_edit(source, node, taken:, otherwise:, removable:)
        # Modifier `stmt if cond` or `stmt unless cond`
        if node.end_keyword_loc.nil?
          return remove_node_edit(source, node, removable: removable) unless taken

          return replace_node_edit(node, lower_node(source, node.statements))
        end

        if taken
          keep_branch_edit(
            source, node, node.statements,
            open_end: predicate_end(node),
            close_start: (otherwise&.location || node.end_keyword_loc).start_offset,
            removable: removable
          )
        elsif otherwise.is_a?(Prism::ElseNode)
          keep_branch_edit(
            source, node, otherwise.statements,
            open_end: otherwise.else_keyword_loc.end_offset,
            close_start: node.end_keyword_loc.start_offset,
            removable: removable
          )
        elsif otherwise
          # `if false ... elsif cond2 ... end` -> lower `if cond2 ... end`
          replace_node_edit(node, lower("if" + slice(source, otherwise.if_keyword_loc.end_offset, node.location.end_offset)))
        else
          remove_node_edit(source, node, removable: removable)
        end
      end

      # An `elsif` sits inside an outer `if` whose predicate was not folded, so its
      # edit reaches to the `end` that closes the whole chain.
      def elsif_edit(source, node)
        value = browser_predicate_value(node.predicate)
        return if value.nil?

        start = node.location.start_offset
        chain_end = find_elsif_chain_end(node)
        if value
          close_start = node.subsequent&.location&.start_offset || chain_end
          replacement = "else#{lower_slice(source, predicate_end(node), close_start)}"
          Edit.new(start_offset: start, end_offset: chain_end, replacement: replacement)
        elsif node.subsequent
          replacement = lower_subsequent_clause(slice(source, node.subsequent.location.start_offset, chain_end))
          Edit.new(start_offset: start, end_offset: chain_end, replacement: replacement)
        else
          # Drop trailing dead `elsif` cleanly up to the closing `end` line
          start = self.class.line_start_of(source, start) if self.class.only_whitespace_before_on_line?(source, start)
          Edit.new(start_offset: start, end_offset: self.class.line_start_of(source, chain_end), replacement: "")
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
        lowered = lower(wrapper)
        lowered.delete_prefix("if __ir_keep__\n").delete_suffix("end\n")
      end

      def scoped_block_call?(node)
        SCOPED_BLOCK_METHODS.include?(node.name) &&
          (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)) &&
          node.arguments.nil? &&
          node.block.is_a?(Prism::BlockNode)
      end

      def keep_block?(name)
        if @runtime == :client
          CLIENT_BLOCK_METHODS.include?(name)
        else
          name == :server_only
        end
      end

      def syncable_include_call?(node)
        return false unless node.name == :include && node.receiver.nil? && node.block.nil?

        args = node.arguments&.arguments
        return false unless args && args.length == 1

        name = self.class.constant_name(args.first)
        name == "InstantRecord::Syncable" || name == "::InstantRecord::Syncable"
      end

      # true or false when the runtime decides `node`, nil when it does not.
      def browser_predicate_value(node)
        case node
        when Prism::ParenthesesNode
          stmts = node.body&.body
          stmts && stmts.length == 1 ? browser_predicate_value(stmts.first) : nil
        when Prism::CallNode
          return unless node.arguments.nil? && node.block.nil?

          if node.name == :browser?
            recv = self.class.constant_name(node.receiver)
            @runtime == :client if recv == "InstantRecord" || recv == "::InstantRecord"
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

      def unwrap_block_edit(source, call_node, removable:)
        block = call_node.block
        return remove_node_edit(source, call_node, removable: removable) if block.body.nil?

        opening = block.opening_loc
        closing = block.closing_loc
        if opening.start_line != closing.start_line && full_line_node?(source, call_node)
          body_start = self.class.line_end_after(source, opening.end_offset)
          body_end = self.class.line_start_of(source, closing.start_offset)
          keep_lines_edit(source, call_node, body_start, body_end, removable: removable)
        else
          replace_node_edit(call_node, lower_node(source, block.body))
        end
      end

      def keep_branch_edit(source, node, statements, open_end:, close_start:, removable:)
        return remove_node_edit(source, node, removable: removable) if statements.nil?

        if full_line_node?(source, node)
          body_start = self.class.line_end_after(source, open_end)
          body_end = self.class.line_start_of(source, close_start)
          return keep_lines_edit(source, node, body_start, body_end, removable: removable) if body_end > body_start
        end

        replace_node_edit(node, lower_node(source, statements))
      end

      def keep_lines_edit(source, node, body_start, body_end, removable:)
        indent = self.class.leading_indent(source, node.location.start_offset)
        body = self.class.reindent_block(lower_slice(source, body_start, body_end), target_indent: indent)
        return remove_node_edit(source, node, removable: removable) if body.empty?

        replace_lines_edit(source, node, body)
      end

      def remove_node_edit(source, node, removable:)
        if removable && full_line_node?(source, node)
          replace_lines_edit(source, node, "")
        else
          replace_node_edit(node, "nil")
        end
      end

      def replace_node_edit(node, replacement)
        Edit.new(start_offset: node.location.start_offset, end_offset: node.location.end_offset, replacement: replacement)
      end

      def replace_lines_edit(source, node, replacement)
        Edit.new(
          start_offset: self.class.line_start_of(source, node.location.start_offset),
          end_offset: self.class.line_end_after(source, node.location.end_offset),
          replacement: replacement
        )
      end

      def full_line_node?(source, node)
        self.class.only_whitespace_before_on_line?(source, node.location.start_offset) &&
          self.class.only_whitespace_or_comment_after_on_line?(source, node.location.end_offset)
      end

      def lower_node(source, node)
        lower_slice(source, node.location.start_offset, node.location.end_offset)
      end

      def lower_slice(source, start_offset, end_offset)
        lower(slice(source, start_offset, end_offset))
      end

      def slice(source, start_offset, end_offset)
        self.class.byteslice(source, start_offset, end_offset - start_offset)
      end
    end
  end
end
