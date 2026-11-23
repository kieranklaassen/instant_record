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
        visit(source, root, edits, parent: nil, statement_context: false, value_preserving_last: false)
        edits
      end

      def visit(source, node, edits, parent:, statement_context:, value_preserving_last:)
        return if node.nil?

        case node
        when Prism::StatementsNode
          visit_statements(source, node, edits, parent: parent)
        when Prism::CallNode
          return if handle_call(source, node, edits, statement_context: statement_context, value_preserving_last: value_preserving_last)

          visit_children(source, node, edits)
        when Prism::IfNode
          return if handle_if(source, node, edits, statement_context: statement_context, value_preserving_last: value_preserving_last)

          visit_children(source, node, edits)
        when Prism::UnlessNode
          return if handle_unless(source, node, edits, statement_context: statement_context, value_preserving_last: value_preserving_last)

          visit_children(source, node, edits)
        when Prism::AndNode
          return if handle_and(source, node, edits)

          visit_children(source, node, edits)
        when Prism::OrNode
          return if handle_or(source, node, edits)

          visit_children(source, node, edits)
        else
          visit_children(source, node, edits)
        end
      end

      def visit_statements(source, node, edits, parent:)
        body = node.body
        preserve_last = body.length > 1 && value_returning_owner?(parent)
        body.each_with_index do |stmt, index|
          is_last = index == body.length - 1
          visit(
            source,
            stmt,
            edits,
            parent: node,
            statement_context: true,
            value_preserving_last: preserve_last && is_last
          )
        end
      end

      def visit_children(source, node, edits)
        node.compact_child_nodes.each do |child|
          visit(source, child, edits, parent: node, statement_context: false, value_preserving_last: false)
        end
      end

      def value_returning_owner?(node)
        node.is_a?(Prism::DefNode) ||
          node.is_a?(Prism::BlockNode) ||
          node.is_a?(Prism::LambdaNode) ||
          node.is_a?(Prism::ParenthesesNode)
      end

      def handle_call(source, node, edits, statement_context:, value_preserving_last:)
        if scoped_block_call?(node)
          if keep_block?(node.name)
            edits << unwrap_block_edit(source, node, statement_context: statement_context, value_preserving_last: value_preserving_last)
          else
            edits << remove_node_edit(source, node, statement_context: statement_context, value_preserving_last: value_preserving_last)
          end
          return true
        end

        if @rewrite_syncable_include && syncable_include_call?(node)
          arg = node.arguments.arguments.first
          edits << Edit.new(
            start_offset: arg.location.start_offset,
            end_offset: arg.location.end_offset,
            replacement: "Syncable"
          )
          return true
        end

        if (folded = browser_predicate_value(node))
          edits << Edit.new(
            start_offset: node.location.start_offset,
            end_offset: node.location.end_offset,
            replacement: folded == :true ? "true" : "false"
          )
          return true
        end

        false
      end

      def handle_and(source, node, edits)
        lhs = browser_predicate_value(node.left)
        return false unless lhs

        replacement =
          if lhs == :false
            "false"
          else
            lower_slice(source, node.right.location.start_offset, node.right.location.end_offset)
          end
        edits << Edit.new(
          start_offset: node.location.start_offset,
          end_offset: node.location.end_offset,
          replacement: replacement
        )
        true
      end

      def handle_or(source, node, edits)
        lhs = browser_predicate_value(node.left)
        return false unless lhs

        replacement =
          if lhs == :true
            "true"
          else
            lower_slice(source, node.right.location.start_offset, node.right.location.end_offset)
          end
        edits << Edit.new(
          start_offset: node.location.start_offset,
          end_offset: node.location.end_offset,
          replacement: replacement
        )
        true
      end

      def handle_if(source, node, edits, statement_context:, value_preserving_last:)
        # Handle `elsif` clauses differently: they sit inside an outer `if` whose
        # predicate was NOT statically folded.
        if node.if_keyword_loc&.slice == "elsif"
          return handle_elsif(source, node, edits)
        end

        pred = browser_predicate_value(node.predicate)
        return false unless pred

        # Ternary: `cond ? a : b`
        if node.if_keyword_loc.nil?
          chosen = pred == :true ? node.statements : node.subsequent&.statements
          replacement = chosen ? lower_slice(source, chosen.location.start_offset, chosen.location.end_offset) : "nil"
          edits << Edit.new(
            start_offset: node.location.start_offset,
            end_offset: node.location.end_offset,
            replacement: replacement
          )
          return true
        end

        # Modifier `stmt if cond`
        if node.end_keyword_loc.nil?
          if pred == :true
            body = node.statements
            replacement = lower_slice(source, body.location.start_offset, body.location.end_offset)
            edits << Edit.new(
              start_offset: node.location.start_offset,
              end_offset: node.location.end_offset,
              replacement: replacement
            )
          else
            edits << remove_node_edit(source, node, statement_context: statement_context, value_preserving_last: value_preserving_last)
          end
          return true
        end

        # Full `if ... [elsif ...] [else ...] end`
        if pred == :true
          edits << replace_branch_edit(
            source,
            node,
            open_end_offset: node.then_keyword_loc ? node.then_keyword_loc.end_offset : node.predicate.location.end_offset,
            close_start_offset: node.subsequent ? node.subsequent.location.start_offset : node.end_keyword_loc.start_offset,
            statements: node.statements,
            statement_context: statement_context,
            value_preserving_last: value_preserving_last
          )
        elsif node.subsequent.is_a?(Prism::ElseNode)
          else_node = node.subsequent
          edits << replace_branch_edit(
            source,
            node,
            open_end_offset: else_node.else_keyword_loc.end_offset,
            close_start_offset: node.end_keyword_loc.start_offset,
            statements: else_node.statements,
            statement_context: statement_context,
            value_preserving_last: value_preserving_last
          )
        elsif node.subsequent.is_a?(Prism::IfNode)
          # `if false ... elsif cond2 ... end` -> lower `if cond2 ... end`
          sub = node.subsequent
          promoted = "if" + self.class.byteslice(source, sub.if_keyword_loc.end_offset, node.location.end_offset - sub.if_keyword_loc.end_offset)
          lowered = lower(promoted)
          edits << Edit.new(
            start_offset: node.location.start_offset,
            end_offset: node.location.end_offset,
            replacement: lowered
          )
        else
          edits << remove_node_edit(source, node, statement_context: statement_context, value_preserving_last: value_preserving_last)
        end

        true
      end

      def handle_elsif(source, node, edits)
        pred = browser_predicate_value(node.predicate)
        return false unless pred

        # Locate the outer `end` that closes this `if`/`elsif` chain.
        chain_end = find_elsif_chain_end(node)
        if pred == :true
          open_end = node.then_keyword_loc ? node.then_keyword_loc.end_offset : node.predicate.location.end_offset
          close_start = node.subsequent ? node.subsequent.location.start_offset : chain_end
          body_raw = self.class.byteslice(source, open_end, close_start - open_end)
          lowered_body = lower(body_raw)
          replacement = "else#{lowered_body}"
          edits << Edit.new(
            start_offset: node.location.start_offset,
            end_offset: chain_end,
            replacement: replacement
          )
        else
          if node.subsequent
            sub_raw = self.class.byteslice(source, node.subsequent.location.start_offset, chain_end - node.subsequent.location.start_offset)
            # Lower subsequent recursively by wrapping in a dummy `if __x__\n...\nend` if needed
            lowered_sub = lower_subsequent_clause(sub_raw)
            edits << Edit.new(
              start_offset: node.location.start_offset,
              end_offset: chain_end,
              replacement: lowered_sub
            )
          else
            # Drop trailing dead `elsif` cleanly up to the closing `end` line
            start_pos = self.class.only_whitespace_before_on_line?(source, node.location.start_offset) ?
              self.class.line_start_of(source, node.location.start_offset) : node.location.start_offset
            end_pos = self.class.line_start_of(source, chain_end)
            edits << Edit.new(start_offset: start_pos, end_offset: end_pos, replacement: "")
          end
        end

        true
      end

      def find_elsif_chain_end(node)
        curr = node
        while curr
          return curr.end_keyword_loc.start_offset if curr.respond_to?(:end_keyword_loc) && curr.end_keyword_loc

          curr = curr.respond_to?(:subsequent) ? curr.subsequent : nil
        end
        node.location.end_offset
      end

      def lower_subsequent_clause(sub_raw)
        wrapper = "if __ir_keep__\n#{sub_raw}end\n"
        lowered = lower(wrapper)
        lowered.delete_prefix("if __ir_keep__\n").delete_suffix("end\n")
      end

      def handle_unless(source, node, edits, statement_context:, value_preserving_last:)
        pred = browser_predicate_value(node.predicate)
        return false unless pred

        # Modifier `stmt unless cond`
        if node.end_keyword_loc.nil?
          if pred == :false
            body = node.statements
            replacement = lower_slice(source, body.location.start_offset, body.location.end_offset)
            edits << Edit.new(
              start_offset: node.location.start_offset,
              end_offset: node.location.end_offset,
              replacement: replacement
            )
          else
            edits << remove_node_edit(source, node, statement_context: statement_context, value_preserving_last: value_preserving_last)
          end
          return true
        end

        # Block `unless cond ... [else ...] end`
        if pred == :false
          edits << replace_branch_edit(
            source,
            node,
            open_end_offset: node.then_keyword_loc ? node.then_keyword_loc.end_offset : node.predicate.location.end_offset,
            close_start_offset: node.else_clause ? node.else_clause.location.start_offset : node.end_keyword_loc.start_offset,
            statements: node.statements,
            statement_context: statement_context,
            value_preserving_last: value_preserving_last
          )
        elsif node.else_clause
          edits << replace_branch_edit(
            source,
            node,
            open_end_offset: node.else_clause.else_keyword_loc.end_offset,
            close_start_offset: node.end_keyword_loc.start_offset,
            statements: node.else_clause.statements,
            statement_context: statement_context,
            value_preserving_last: value_preserving_last
          )
        else
          edits << remove_node_edit(source, node, statement_context: statement_context, value_preserving_last: value_preserving_last)
        end

        true
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

      def browser_predicate_value(node)
        case node
        when Prism::ParenthesesNode
          stmts = node.body&.body
          stmts && stmts.length == 1 ? browser_predicate_value(stmts.first) : nil
        when Prism::CallNode
          if node.name == :browser? && node.arguments.nil? && node.block.nil?
            recv = self.class.constant_name(node.receiver)
            if recv == "InstantRecord" || recv == "::InstantRecord"
              return @runtime == :client ? :true : :false
            end
          elsif node.name == :! && node.arguments.nil? && node.block.nil?
            inner = browser_predicate_value(node.receiver)
            return inner == :true ? :false : :true if inner
          end
          nil
        when Prism::AndNode
          lhs = browser_predicate_value(node.left)
          return :false if lhs == :false
          return browser_predicate_value(node.right) if lhs == :true

          nil
        when Prism::OrNode
          lhs = browser_predicate_value(node.left)
          return :true if lhs == :true
          return browser_predicate_value(node.right) if lhs == :false

          nil
        end
      end

      def unwrap_block_edit(source, call_node, statement_context:, value_preserving_last:)
        block = call_node.block
        if block.body.nil?
          return remove_node_edit(source, call_node, statement_context: statement_context, value_preserving_last: value_preserving_last)
        end

        opening = block.opening_loc
        closing = block.closing_loc
        multiline = opening.start_line != closing.start_line

        if multiline && full_line_node?(source, call_node)
          open_end = self.class.line_end_after(source, opening.end_offset)
          close_start = self.class.line_start_of(source, closing.start_offset)
          inner_raw = self.class.byteslice(source, open_end, close_start - open_end)
          lowered_inner = lower(inner_raw)
          indent = self.class.leading_indent(source, call_node.location.start_offset)
          replacement = self.class.reindent_block(lowered_inner, target_indent: indent)

          if replacement.empty?
            return remove_node_edit(source, call_node, statement_context: statement_context, value_preserving_last: value_preserving_last)
          end

          Edit.new(
            start_offset: self.class.line_start_of(source, call_node.location.start_offset),
            end_offset: self.class.line_end_after(source, call_node.location.end_offset),
            replacement: replacement
          )
        else
          body_loc = block.body.location
          replacement = lower_slice(source, body_loc.start_offset, body_loc.end_offset)
          Edit.new(
            start_offset: call_node.location.start_offset,
            end_offset: call_node.location.end_offset,
            replacement: replacement
          )
        end
      end

      def replace_branch_edit(source, node, open_end_offset:, close_start_offset:, statements:, statement_context:, value_preserving_last:)
        if statements.nil?
          return remove_node_edit(source, node, statement_context: statement_context, value_preserving_last: value_preserving_last)
        end

        if full_line_node?(source, node) && node.location.start_line != node.location.end_line
          body_start = self.class.line_end_after(source, open_end_offset)
          body_end = self.class.line_start_of(source, close_start_offset)
          if body_end > body_start
            inner_raw = self.class.byteslice(source, body_start, body_end - body_start)
            lowered_inner = lower(inner_raw)
            indent = self.class.leading_indent(source, node.location.start_offset)
            replacement = self.class.reindent_block(lowered_inner, target_indent: indent)
            if replacement.empty?
              return remove_node_edit(source, node, statement_context: statement_context, value_preserving_last: value_preserving_last)
            end

            return Edit.new(
              start_offset: self.class.line_start_of(source, node.location.start_offset),
              end_offset: self.class.line_end_after(source, node.location.end_offset),
              replacement: replacement
            )
          end
        end

        replacement = lower_slice(source, statements.location.start_offset, statements.location.end_offset)
        Edit.new(
          start_offset: node.location.start_offset,
          end_offset: node.location.end_offset,
          replacement: replacement
        )
      end

      def remove_node_edit(source, node, statement_context:, value_preserving_last:)
        if statement_context && !value_preserving_last && full_line_node?(source, node)
          Edit.new(
            start_offset: self.class.line_start_of(source, node.location.start_offset),
            end_offset: self.class.line_end_after(source, node.location.end_offset),
            replacement: ""
          )
        else
          Edit.new(
            start_offset: node.location.start_offset,
            end_offset: node.location.end_offset,
            replacement: "nil"
          )
        end
      end

      def full_line_node?(source, node)
        self.class.only_whitespace_before_on_line?(source, node.location.start_offset) &&
          self.class.only_whitespace_or_comment_after_on_line?(source, node.location.end_offset)
      end

      def lower_slice(source, start_offset, end_offset)
        lower(self.class.byteslice(source, start_offset, end_offset - start_offset))
      end
    end
  end
end
