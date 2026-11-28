require "pathname"
require "prism"
require "set"
require_relative "ast_lowerer"
require_relative "runner"

module InstantRecord
  class Compiler
    # Fast pre-Spinel Prism static AOT / 32-bit linter.
    #
    # Catches the three silent/slow AOT failure classes before Roundhouse or
    # Spinel run (and in `instant_record:doctor`):
    #
    # 1. `integer_overflow`: integer literals and constant expressions exceeding
    #    signed 32-bit / 31-bit-magnitude range (-2_147_483_648..2_147_483_647),
    #    which raise RangeError under `-DSP_INT_OVERFLOW_MODE_RAISE`.
    # 2. `untyped_screen_hash`: untyped empty `{}` (or `Hash.new`) passed to
    #    `params:`, `args:`, or `props:` (or defaulted/assigned there) inside
    #    `InstantRecord::Native::Screen` subclasses / `app/screens/`.
    # 3. `server_only_constant`: references from shared / `browser_only` /
    #    `client_only` code to constants defined only inside `server_only`
    #    blocks (or server-only gem constants).
    class StaticLinter
      INT32_MAX = (1 << 31) - 1 #  2_147_483_647 (31 magnitude bits)
      INT32_MIN = -(1 << 31)    # -2_147_483_648
      INT32_RANGE = (INT32_MIN..INT32_MAX)

      SCREEN_HASH_KEYS = %i[params args props].freeze
      SCREEN_HASH_SETTERS = %i[link_params= args= props=].freeze
      SCREEN_HASH_IVARS = %i[@link_params @args @props].freeze

      BYTE_MULTIPLIERS = {
        kilobyte: 1024, kilobytes: 1024, kb: 1024,
        megabyte: 1024**2, megabytes: 1024**2, mb: 1024**2,
        gigabyte: 1024**3, gigabytes: 1024**3, gb: 1024**3,
        terabyte: 1024**4, terabytes: 1024**4, tb: 1024**4,
        petabyte: 1024**5, petabytes: 1024**5, pb: 1024**5
      }.freeze

      SERVER_ONLY_GEM_CONSTANTS = Set.new(%w[
        InstantRecord::Engine
        InstantRecord::Files
        InstantRecord::FileStore
        InstantRecord::MutationApplier
        InstantRecord::AppliedMutation
        InstantRecord::SyncScope
        InstantRecord::Inertia::Renderer
        InstantRecord::CompiledSite
        InstantRecord::Compiler
      ]).freeze

      SERVER_ONLY = "server_only".b.freeze
      BEGIN_COMMENT = "=begin".b.freeze
      BROWSER_Q = "browser?".b.freeze
      SCREEN_B = "Screen".b.freeze
      HASH_B = "Hash".b.freeze
      LBRACE_B = "{".b.freeze
      STAR_B = "*".b.freeze
      LSHIFT_B = "<<".b.freeze
      PLUS_B = "+".b.freeze
      MINUS_B = "-".b.freeze
      PIPE_B = "|".b.freeze
      CARET_B = "^".b.freeze
      AMP_B = "&".b.freeze
      EQ_B = "=".b.freeze
      NUL_B = "\0".b.freeze
      CODING_RE = /coding[ \t\r\f\v]*[:=][ \t\r\f\v]*["']?([A-Za-z0-9_\-]*)/in
      ASCII_COMPAT_ENC_RE = /\A(?:utf-?8|us-?ascii|ascii|ascii-?8bit|binary|iso-?8859-\d+|latin\d*|windows-?125\d)\z/i
      HEREDOC_START_RE = /<<[~\-'"`A-Za-z0-9_\x80-\xFF\\]/n

      # Sound byte-level prefilter regexes (ASCII-8BIT /n) used only on verified
      # ASCII-compatible source files without `=begin` block comments.
      HWS = "(?:[ \\t\\r\\f\\v]|\\\\\\r?\\n)*"
      WS_CMT = "(?:[ \\t\\r\\n\\f\\v\\\\]|#[^\\n]*\\n)*"

      DIGIT_RE = /[0-9]/n
      BIG_LIT_RE = /(?:[0-9](?:_?[0-9]){9,}|0[xX][0-9a-fA-F](?:_?[0-9a-fA-F]){7,}|0[oO0-7](?:_?[0-7]){9,}|0[bB][01](?:_?[01]){30,})/n
      MED_LIT_RE = /(?:[1-9](?:_?[0-9]){4,}|0[xX][0_]*[1-9a-fA-F](?:_?[0-9a-fA-F]){3,}|0[oO]?[0_]*[1-7](?:_?[0-7]){5,}|0[bB][0_]*1(?:_?[01]){14,})/n
      BYTE_MULT_WORD_RE = /\b(?:(?:kilo|mega|giga|tera|peta)bytes?|[kmgtp]b)\b/n
      BYTE_MULT_RE = /(?:\.|::)(?:[ \t\r\n\f\v\\]|#[^\n]*\n)*(?:(?:kilo|mega|giga|tera|peta)bytes?|[kmgtp]b)(?![A-Za-z0-9_\x80-\xFF])/n
      BEGIN_COMMENT_RE = /(?:\A(?:\xEF\xBB\xBF)?|\n)=begin(?:[ \t\r\f\v\n]|\z)/n
      SCREEN_INHERIT_RE = Regexp.new("<#{WS_CMT}(?:::#{WS_CMT})?(?:InstantRecord#{WS_CMT}::#{WS_CMT})?(?:Native#{WS_CMT}::#{WS_CMT})?Screen(?![A-Za-z0-9_\\x80-\\xFF])", Regexp::NOENCODING)
      EMPTY_HASH_LIT_RE = /\{(?:[ \t\r\n\f\v\\]|#[^\n]*\n)*\}|\bHash(?:[ \t\r\n\f\v\\]|#[^\n]*\n)*(?:&?\.|::)(?:[ \t\r\n\f\v\\]|#[^\n]*\n)*new(?![A-Za-z0-9_\x80-\xFF])/n
      SERVER_ONLY_BLOCK_RE = /(?<![A-Za-z0-9_\x80-\xFF])server_only(?:[ \t\r\f\v]|\\\r?\n)*(?:\{|do(?![A-Za-z0-9_\x80-\xFF])|\((?=[ \t\r\n\f\v#)=\\]))/n
      ANY_CONST_DEF_RE = /(?<![A-Za-z0-9_\x80-\xFF])(?:(?:class|module)(?![A-Za-z0-9_\x80-\xFF])|[A-Z\x80-\xFF][A-Za-z0-9_\x80-\xFF]*(?:[ \t\r\f\v]|\\\r?\n)*(?:(?:\|\||&&|[+\-*\/%&|^]|<<|>>|\*\*)=|=(?![=>~])))/n

      # Operations that can produce an overflowing Integer from non-overflowing
      # 32-bit signed operands. Other ops (+@, ~, %, &, |, ^, >>) are still
      # evaluated inside eval_const_int when nested inside an outer expression.
      OVERFLOW_OPS = {
        :-@ => true, :+ => true, :- => true, :* => true,
        :/ => true, :** => true, :<< => true
      }.merge(BYTE_MULTIPLIERS.transform_values { true }).freeze

      SCREEN_HASH_KEYS_MAP = { params: true, args: true, props: true }.freeze
      SCREEN_HASH_SETTERS_MAP = { :link_params= => true, :args= => true, :props= => true }.freeze
      SCREEN_HASH_IVARS_MAP = { :@link_params => true, :@args => true, :@props => true }.freeze
      HASH_MUTATION_OPS = { :[]= => true, store: true, merge!: true, update: true }.freeze
      SCREEN_SUPERCLASSES = {
        "InstantRecord::Native::Screen" => true,
        "Native::Screen" => true,
        "Screen" => true
      }.freeze

      private_constant :SERVER_ONLY, :BEGIN_COMMENT, :BROWSER_Q, :SCREEN_B, :HASH_B,
                       :LBRACE_B, :STAR_B, :LSHIFT_B, :PLUS_B, :MINUS_B, :PIPE_B, :CARET_B, :AMP_B, :EQ_B, :NUL_B,
                       :CODING_RE, :ASCII_COMPAT_ENC_RE, :HEREDOC_START_RE,
                       :HWS, :WS_CMT,
                       :DIGIT_RE, :BIG_LIT_RE, :MED_LIT_RE, :BYTE_MULT_WORD_RE, :BYTE_MULT_RE,
                       :BEGIN_COMMENT_RE, :SCREEN_INHERIT_RE, :EMPTY_HASH_LIT_RE,
                       :SERVER_ONLY_BLOCK_RE, :ANY_CONST_DEF_RE,
                       :OVERFLOW_OPS, :SCREEN_HASH_KEYS_MAP, :SCREEN_HASH_SETTERS_MAP,
                       :SCREEN_HASH_IVARS_MAP, :HASH_MUTATION_OPS, :SCREEN_SUPERCLASSES

      NON_COMPILED_PREFIXES = %w[
        db/
        test/
        spec/
        tmp/
        vendor/
        node_modules/
        lib/tasks/
        lib/generators/
      ].freeze

      NON_COMPILED_FILES = Set.new(%w[
        Gemfile
        Rakefile
      ]).freeze

      # Where compiled code lives in a Rails app.
      RAILS_FOLDERS = %w[app/models app/controllers app/helpers app/screens config/routes].freeze
      RAILS_FILES = %w[config/application.rb config/routes.rb config/importmap.rb].freeze
      private_constant :RAILS_FOLDERS, :RAILS_FILES

      Diagnostic = Struct.new(:rule, :file, :line, :column, :message, keyword_init: true) do
        def to_s
          "#{file}:#{line}:#{column} [#{rule}] #{message}"
        end
      end

      Result = Struct.new(:files_checked, :diagnostics, keyword_init: true) do
        def ok? = diagnostics.empty?

        def to_s
          return "Static AOT lint passed (#{files_checked} files checked)." if ok?

          lines = ["Static AOT lint failed with #{diagnostics.size} issue(s) across #{files_checked} files:"]
          diagnostics.each { |d| lines << "  #{d}" }
          lines.join("\n")
        end
      end

      # Per-run lazy source & parse cache for a single file.
      class SourceEntry
        attr_reader :path, :rel, :bytes, :ascii_compat

        def initialize(path, rel, bytes, ascii_compat)
          @path = path
          @rel = rel
          @bytes = bytes
          @ascii_compat = ascii_compat
          @parsed = nil
        end

        def parsed
          @parsed ||= Prism.parse(@bytes)
        end
      end
      private_constant :SourceEntry

      def self.lint(root, staged: false, server_only_constants: nil, exclude: [], only_files: nil)
        new(root: root, staged: staged, server_only_constants: server_only_constants, exclude: exclude, only_files: only_files).run
      end

      def self.check!(root, staged: true, server_only_constants: nil, exclude: [], only_files: nil)
        result = lint(root, staged: staged, server_only_constants: server_only_constants, exclude: exclude, only_files: only_files)
        raise BuildError, result.to_s unless result.ok?

        result
      end

      # Collects constants defined strictly inside `server_only` blocks across a
      # directory tree before AstLowerer strips those blocks.
      def self.collect_server_only_constants(root, staged: true, exclude: [], only_files: nil)
        linter = new(root: root, staged: staged, exclude: exclude, only_files: only_files)
        files = linter.discover_files
        linter.scan_constant_definitions(files)
      end

      def initialize(root:, staged: false, server_only_constants: nil, exclude: [], only_files: nil)
        @root = File.expand_path(root.to_s)
        @root_prefix = @root == "/" ? "/" : "#{@root}/"
        @staged = staged
        @precollected_server_only = server_only_constants
        @exclude = Array(exclude).map { |entry| entry.to_s.sub(%r{\A/+}, "").sub(%r{/+\z}, "") }
        @only_files = only_files ? Set.new(Array(only_files).map { |entry| entry.to_s.sub(%r{\A/+}, "") }) : nil
      end

      def run
        files = discover_files
        entries = load_entries(files)

        server_only_defs = @precollected_server_only || collect_server_only_defs(entries)
        names = server_only_defs.empty? ? SERVER_ONLY_GEM_CONSTANTS.to_a : (server_only_defs.keys + SERVER_ONLY_GEM_CONSTANTS.to_a)
        client_defs = collect_client_defs(entries, names)

        # Constant name => where it is defined, nil for a gem constant.
        server_only = {}
        server_only_defs.each do |name, loc|
          server_only[name] = loc unless client_defs.include?(name)
        end
        SERVER_ONLY_GEM_CONSTANTS.each do |name|
          server_only[name] ||= nil unless client_defs.include?(name)
        end

        so_leaf_syms = {}
        so_last_words = []
        so_key_segments = []
        server_only.each_key do |full_name|
          segs = full_name.split("::")
          last = segs.last
          so_leaf_syms[last.to_sym] = true
          so_last_words << last.b
          so_key_segments << segs.map(&:b).uniq
        end
        so_last_words.uniq!
        so_last_re = so_last_words.empty? ? nil : build_union_regex(so_last_words)

        diagnostics = []
        visitor = LintVisitor.new(diagnostics, server_only, so_leaf_syms)

        entries.each do |entry|
          rel = entry.rel
          in_screen_path = rel.start_with?("app/screens/") ||
                           rel == "lib/instant_record/native/screen.rb" ||
                           rel == "lib/instant_record/native/node.rb"

          need_int = may_overflow_int?(entry)
          need_screen = may_have_untyped_screen_hash?(entry, in_screen_path)
          need_so = may_ref_server_only?(entry, so_last_re, so_key_segments)
          next unless need_int || need_screen || need_so

          parsed = entry.parsed
          next unless parsed.success?

          bytes = entry.bytes
          ascii = entry.ascii_compat
          visitor.lint_file(
            rel,
            parsed.value,
            in_screen_path: in_screen_path,
            need_int: need_int,
            need_screen: need_screen,
            need_so: need_so,
            has_browser: !ascii || bytes.include?(BROWSER_Q),
            has_server_only: !ascii || bytes.include?(SERVER_ONLY)
          )
        end

        diagnostics.sort_by! { |d| [d.file, d.line, d.column, d.rule.to_s] } if diagnostics.length > 1
        Result.new(files_checked: entries.size, diagnostics: diagnostics)
      end

      def discover_files
        return [] unless File.directory?(@root)

        candidates =
          if @only_files
            @only_files
          elsif !@staged && rails_layout?
            # Raw Rails app root (used by `instant_record:doctor`): scan only
            # what enters compilation.
            rails_files
          else
            # Staged tree or standalone fixture directory.
            Dir.glob("**/*.rb", base: @root).reject { |rel| excluded_staged?(rel) }
          end

        filtered = @exclude.empty? ? candidates.to_a : candidates.reject { |rel| excluded_custom?(rel) }
        filtered.sort!
        paths = filtered.map { |rel| "#{@root_prefix}#{rel}" }
        @only_files ? paths.select { |path| File.file?(path) } : paths
      end

      def scan_constant_definitions(files)
        entries = load_entries(files)
        server_only_defs = collect_server_only_defs(entries)
        return server_only_defs if server_only_defs.empty?

        client_defs = collect_client_defs(entries, server_only_defs.keys)
        server_only_defs.reject { |name, _| client_defs.include?(name) }
      end

      private

      def load_entries(files)
        files.map do |path|
          bytes = File.binread(path)
          SourceEntry.new(path, relative_path(path), bytes, ascii_compatible_source?(bytes))
        end
      end

      def ascii_compatible_source?(bytes)
        return false if bytes.include?(NUL_B)

        pos = 0
        len = bytes.bytesize
        if len >= 3 && bytes.getbyte(0) == 0xEF && bytes.getbyte(1) == 0xBB && bytes.getbyte(2) == 0xBF
          pos = 3
        end
        pos = skip_leading_hws(bytes, pos, len)
        return true unless pos < len && bytes.getbyte(pos) == 35

        nl1 = bytes.byteindex("\n".b, pos)
        line1 = bytes.byteslice(pos, (nl1 || len) - pos)
        return false unless ascii_compatible_coding_line?(line1)

        if nl1
          pos2 = skip_leading_hws(bytes, nl1 + 1, len)
          if pos2 < len && bytes.getbyte(pos2) == 35
            nl2 = bytes.byteindex("\n".b, pos2)
            line2 = bytes.byteslice(pos2, (nl2 || len) - pos2)
            return false unless ascii_compatible_coding_line?(line2)
          end
        end

        true
      end

      def skip_leading_hws(bytes, pos, len)
        while pos < len && ((b = bytes.getbyte(pos)) == 32 || b == 9 || b == 13 || b == 12 || b == 11)
          pos += 1
        end
        pos
      end

      def ascii_compatible_coding_line?(line)
        scan_pos = 0
        while (m = CODING_RE.match(line, scan_pos))
          return false unless ASCII_COMPAT_ENC_RE.match?(m[1])

          scan_pos = m.end(0)
        end
        true
      end

      def rails_layout?
        RAILS_FOLDERS.any? { |dir| File.directory?(File.join(@root, dir)) } ||
          RAILS_FILES.any? { |file| File.file?(File.join(@root, file)) }
      end

      def rails_files
        in_folders = RAILS_FOLDERS.flat_map do |folder|
          Dir.glob("**/*.rb", base: File.join(@root, folder)).map { |rel| "#{folder}/#{rel}" }
        end
        in_folders + RAILS_FILES.select { |file| File.file?(File.join(@root, file)) }
      end

      def relative_path(path)
        if path.start_with?(@root_prefix)
          rel = path.byteslice(@root_prefix.bytesize, path.bytesize - @root_prefix.bytesize)
          unless rel.start_with?("./", "../") || rel.include?("/./") || rel.include?("/../") || rel.include?("//") || rel == "." || rel == ".."
            return rel
          end
        end
        Pathname(path).relative_path_from(Pathname(@root)).to_s
      end

      def excluded_staged?(rel)
        return true if NON_COMPILED_FILES.include?(rel)

        NON_COMPILED_PREFIXES.any? { |prefix| rel.start_with?(prefix) }
      end

      def excluded_custom?(rel)
        @exclude.any? { |entry| rel == entry || rel.start_with?("#{entry}/") }
      end

      # --- Sound prefilters ---

      def has_begin_comment?(bytes)
        bytes.include?(BEGIN_COMMENT) && BEGIN_COMMENT_RE.match?(bytes)
      end

      def has_heredoc?(bytes)
        bytes.include?(LSHIFT_B) && HEREDOC_START_RE.match?(bytes)
      end

      def may_define_server_only_const?(entry)
        return true unless entry.ascii_compat

        bytes = entry.bytes
        return false unless bytes.include?(SERVER_ONLY)
        return true if has_begin_comment?(bytes) || has_heredoc?(bytes)

        m = SERVER_ONLY_BLOCK_RE.match(bytes)
        return false unless m

        ANY_CONST_DEF_RE.match?(bytes, m.end(0))
      end

      def may_define_any_const?(entry, words_re, def_re, key_segments)
        return true unless entry.ascii_compat

        bytes = entry.bytes
        return false unless words_re.match?(bytes)
        return false unless key_segments.any? { |segs| segs.all? { |s| bytes.include?(s) } }
        return true if has_begin_comment?(bytes) || has_heredoc?(bytes)

        def_re.match?(bytes)
      end

      def may_overflow_int?(entry)
        return true unless entry.ascii_compat

        bytes = entry.bytes
        return false unless DIGIT_RE.match?(bytes)
        return true if bytes.bytesize >= 200_000
        return true if has_begin_comment?(bytes) || has_heredoc?(bytes)
        return true if BIG_LIT_RE.match?(bytes)
        return true if BYTE_MULT_WORD_RE.match?(bytes) && BYTE_MULT_RE.match?(bytes)
        return true if has_const_op?(bytes, STAR_B, allow_double: true)
        return true if has_const_op?(bytes, LSHIFT_B, allow_double: false)

        # Without `*`, `**`, `<<`, byte multipliers, or `BIG_LIT_RE`, each binary
        # `+`/`-`/`|`/`^`/`&` at most doubles the maximum reachable magnitude even
        # across constant chains (including `-~x == x + 1` bit-extension chains).
        # When every literal is `< 2^15` (no `MED_LIT_RE`) and `bytesize < 200_000`,
        # <= 13 such binary ops cannot exceed `(32_767 + 200_000) * 2^13 < 2^31 - 1`.
        grow_ops = count_const_ops(bytes, PLUS_B, limit: 14)
        grow_ops += count_const_ops(bytes, MINUS_B, limit: 14 - grow_ops) if grow_ops < 14
        grow_ops += count_const_ops(bytes, PIPE_B, limit: 14 - grow_ops, reject_double: true) if grow_ops < 14
        grow_ops += count_const_ops(bytes, CARET_B, limit: 14 - grow_ops) if grow_ops < 14
        grow_ops += count_const_ops(bytes, AMP_B, limit: 14 - grow_ops, reject_double: true) if grow_ops < 14
        return false if grow_ops == 0
        return true if MED_LIT_RE.match?(bytes)

        grow_ops >= 14 && has_first_int_const_assign?(bytes)
      end

      # Operator-anchored scan for binary `*`, `**`, `<<` between
      # valid constant-integer LHS and RHS token boundaries.
      def has_const_op?(bytes, op, allow_double:)
        pos = 0
        op_len = op.bytesize
        op_byte = allow_double ? op.getbyte(0) : nil
        while (idx = bytes.byteindex(op, pos))
          rhs_pos = idx + op_len
          rhs_pos += 1 if op_byte && bytes.getbyte(rhs_pos) == op_byte
          pos = rhs_pos
          next unless valid_const_rhs_at?(bytes, rhs_pos, allow_const: true)
          return true if valid_const_lhs_before?(bytes, idx)
        end
        false
      end

      def count_const_ops(bytes, op, limit:, reject_double: false)
        count = 0
        pos = 0
        op_len = op.bytesize
        op_byte = reject_double ? op.getbyte(0) : nil
        while (idx = bytes.byteindex(op, pos))
          rhs_pos = idx + op_len
          if op_byte && bytes.getbyte(rhs_pos) == op_byte
            pos = rhs_pos + 1
            next
          end
          pos = rhs_pos
          next if op_byte && idx > 0 && bytes.getbyte(idx - 1) == op_byte
          next unless valid_const_rhs_at?(bytes, rhs_pos, allow_const: true)
          if valid_const_lhs_before?(bytes, idx)
            count += 1
            return count if count >= limit
          end
        end
        count
      end

      # Checks whether the file has any `CONST = <int-expr>` that could seed
      # `@const_ints` (when `@const_ints` starts empty, the first constant's RHS
      # must begin with a digit, `(`, `+`, `-`, or `~`, never another constant).
      def has_first_int_const_assign?(bytes)
        pos = 0
        while (idx = bytes.byteindex(EQ_B, pos))
          pos = idx + 1
          nxt = bytes.getbyte(pos)
          # Skip ==, =>, =~
          next if nxt == 61 || nxt == 62 || nxt == 126

          # Skip !=, <=, >=, +=, -=, *=, /=, %=, &=, |=, ^=, ||= , &&=
          prev = idx > 0 ? bytes.getbyte(idx - 1) : nil
          next if prev == 33 || prev == 60 || prev == 62 || prev == 61 ||
                  prev == 43 || prev == 45 || prev == 42 || prev == 47 ||
                  prev == 37 || prev == 38 || prev == 124 || prev == 94

          next unless valid_const_rhs_at?(bytes, pos, allow_const: false)
          return true if valid_const_target_before?(bytes, idx)
        end
        false
      end

      def valid_const_rhs_at?(bytes, pos, allow_const:)
        len = bytes.bytesize
        while pos < len
          b = bytes.getbyte(pos)
          if b == 32 || b == 9 || b == 10 || b == 13 || b == 12 || b == 11 || b == 92
            pos += 1
          elsif b == 35 # `#` comment to EOL
            nl = bytes.byteindex("\n".b, pos + 1)
            return false unless nl

            pos = nl + 1
          else
            return true if (b >= 48 && b <= 57) || b == 40 || b == 43 || b == 45 || b == 126
            if allow_const
              return true if (b >= 65 && b <= 90) || b >= 128
              return true if b == 58 && bytes.getbyte(pos + 1) == 58
            end
            return false
          end
        end
        false
      end

      def valid_const_lhs_before?(bytes, idx)
        j = skip_hws_backward(bytes, idx - 1)
        return false if j < 0

        b = bytes.getbyte(j)
        # Operator at start of line (`1.\n  +(2)` or `1 \\\n + 2`): return
        # conservatively on backslash-terminated lines (which may be a line
        # continuation or a comment ending in `\`), else check whether the
        # preceding non-comment line could end in a dot/scope call operator.
        if b == 10
          return true if backslash_continuation_nl?(bytes, j)

          return preceding_line_ends_with_call_dot?(bytes, j)
        end

        # Handle dot-call operators (`1.+(2)`, `1&.+(2)`, `1::+(2)`).
        if b == 46 # `.`
          j -= 1
          j -= 1 if j >= 0 && bytes.getbyte(j) == 38 # `&.`
          j = skip_hws_backward(bytes, j)
          return false if j < 0
          return true if bytes.getbyte(j) == 10 # multiline dot call: conservative

          b = bytes.getbyte(j)
        elsif b == 58 && j > 0 && bytes.getbyte(j - 1) == 58 # `::`
          j = skip_hws_backward(bytes, j - 2)
          return false if j < 0
          return true if bytes.getbyte(j) == 10

          b = bytes.getbyte(j)
        end

        return true if (b >= 48 && b <= 57) || b == 41 || b == 64 || b == 126 # `0-9`, `)`, `@`, `~`

        if (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95 || b >= 128
          k = j
          while k > 0
            pb = bytes.getbyte(k - 1)
            break unless (pb >= 65 && pb <= 90) || (pb >= 97 && pb <= 122) || (pb >= 48 && pb <= 57) || pb == 95 || pb >= 128

            k -= 1
          end
          first = bytes.getbyte(k)
          return true if (first >= 65 && first <= 90) || first >= 128
          return true if first == 48 && k < j && ((nb = bytes.getbyte(k + 1)) == 120 || nb == 88)
        end

        false
      end

      def preceding_line_ends_with_call_dot?(bytes, nl_idx)
        line_end = nl_idx
        while line_end > 0
          prev_nl = bytes.rindex("\n".b, line_end - 1)
          line_start = prev_nl ? prev_nl + 1 : 0
          # Skip leading horizontal whitespace on the previous line.
          first = line_start
          while first < line_end && ((fb = bytes.getbyte(first)) == 32 || fb == 9 || fb == 13 || fb == 12 || fb == 11)
            first += 1
          end
          # Blank or full-line comment: keep looking at earlier lines.
          if first >= line_end || bytes.getbyte(first) == 35
            return false unless prev_nl

            line_end = prev_nl
            next
          end
          # Strip trailing whitespace and check for trailing `.` or `::`.
          last = line_end - 1
          last -= 1 while last >= first && ((lb = bytes.getbyte(last)) == 32 || lb == 9 || lb == 13 || lb == 12 || lb == 11)
          return true if bytes.getbyte(last) == 46 || bytes.getbyte(last) == 92 # `.` or `\`
          return true if bytes.getbyte(last) == 58 && last > first && bytes.getbyte(last - 1) == 58 # `::`

          # If the line contains `#` (possibly an inline comment after `.` or `::`,
          # or `#` inside a string before a real comment), fall back conservatively
          # whenever `.` or `::` also appears on the line.
          hash_idx = bytes.byteindex("#".b, first)
          if hash_idx && hash_idx < line_end
            dot_idx = bytes.byteindex(".".b, first)
            return true if dot_idx && dot_idx < line_end

            colon_idx = bytes.byteindex("::".b, first)
            return true if colon_idx && colon_idx < line_end
          end
          return false
        end
        false
      end

      def valid_const_target_before?(bytes, idx)
        j = skip_hws_backward(bytes, idx - 1)
        return false if j < 0

        b = bytes.getbyte(j)
        return true if b == 10 && backslash_continuation_nl?(bytes, j)
        return false unless (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || (b >= 48 && b <= 57) || b == 95 || b >= 128

        k = j
        while k > 0
          pb = bytes.getbyte(k - 1)
          break unless (pb >= 65 && pb <= 90) || (pb >= 97 && pb <= 122) || (pb >= 48 && pb <= 57) || pb == 95 || pb >= 128

          k -= 1
        end
        first = bytes.getbyte(k)
        return false unless (first >= 65 && first <= 90) || first >= 128

        # `Foo::BAR = 1` is ConstantPathWriteNode, which does not populate @const_ints.
        !(k >= 2 && bytes.getbyte(k - 1) == 58 && bytes.getbyte(k - 2) == 58)
      end

      def skip_hws_backward(bytes, j)
        while j >= 0
          b = bytes.getbyte(j)
          break unless b == 32 || b == 9 || b == 13 || b == 12 || b == 11

          j -= 1
        end
        j
      end

      def backslash_continuation_nl?(bytes, nl_idx)
        return false if nl_idx <= 0

        prev = bytes.getbyte(nl_idx - 1)
        prev == 92 || (prev == 13 && nl_idx > 1 && bytes.getbyte(nl_idx - 2) == 92)
      end

      def may_have_untyped_screen_hash?(entry, in_screen_path)
        return true unless entry.ascii_compat

        bytes = entry.bytes
        return false unless in_screen_path || bytes.include?(SCREEN_B)
        return false unless bytes.include?(LBRACE_B) || bytes.include?(HASH_B)
        return true if has_begin_comment?(bytes) || has_heredoc?(bytes)
        return false unless in_screen_path || SCREEN_INHERIT_RE.match?(bytes)

        EMPTY_HASH_LIT_RE.match?(bytes)
      end

      def may_ref_server_only?(entry, so_last_re, so_key_segments)
        return false unless so_last_re
        return true unless entry.ascii_compat

        bytes = entry.bytes
        return false unless so_last_re.match?(bytes)

        so_key_segments.any? { |segs| segs.all? { |s| bytes.include?(s) } }
      end

      # --- Constant definitions ---

      def collect_server_only_defs(entries)
        defs = {}
        visitor = ServerOnlyDefVisitor.new(defs)

        entries.each do |entry|
          next unless may_define_server_only_const?(entry)

          parsed = entry.parsed
          next unless parsed.success?

          offsets =
            if entry.ascii_compat && entry.bytes.bytesize >= 1024 && !HEREDOC_START_RE.match?(entry.bytes)
              collect_literal_offsets(entry.bytes, SERVER_ONLY)
            end
          visitor.scan(entry.rel, parsed.value, offsets)
        end

        defs
      end

      def collect_client_defs(entries, names)
        defs = Set.new
        return defs if names.empty?

        remaining = Set.new(names)
        words = last_segments(remaining)
        words_re = build_union_regex(words)
        def_re = build_const_def_regex(words)
        key_segments = remaining.map { |name| name.split("::").map(&:b).uniq }
        visitor = ClientDefVisitor.new(defs, remaining)

        entries.each do |entry|
          next unless may_define_any_const?(entry, words_re, def_re, key_segments)

          parsed = entry.parsed
          next unless parsed.success?

          before_size = defs.size
          bytes = entry.bytes
          offsets =
            if entry.ascii_compat && bytes.bytesize >= 1024 && !HEREDOC_START_RE.match?(bytes)
              collect_regex_offsets(bytes, words_re)
            end
          visitor.scan(parsed.value, offsets, has_server_only: !entry.ascii_compat || bytes.include?(SERVER_ONLY))

          if defs.size > before_size
            remaining.subtract(defs)
            break if remaining.empty?

            words = last_segments(remaining)
            words_re = build_union_regex(words)
            def_re = build_const_def_regex(words)
            key_segments = remaining.map { |name| name.split("::").map(&:b).uniq }
          end
        end

        defs
      end

      # A definition spells the last segment of its name, so a file without the
      # word holds none.
      def last_segments(names)
        names.map { |name| name.rpartition("::").last.b }.uniq
      end

      def build_union_regex(words)
        Regexp.new(words.map { |w| Regexp.escape(w) }.join("|"), Regexp::NOENCODING)
      end

      def build_const_def_regex(words)
        alt = words.map { |w| Regexp.escape(w) }.join("|")
        Regexp.new(
          "(?<![A-Za-z0-9_\\x80-\\xFF])(?:(?:class|module)(?![A-Za-z0-9_\\x80-\\xFF])#{WS_CMT}(?:::#{WS_CMT})?(?:[A-Z\\x80-\\xFF][A-Za-z0-9_\\x80-\\xFF]*#{WS_CMT}::#{WS_CMT})*(?:#{alt})(?![A-Za-z0-9_\\x80-\\xFF])|(?:#{alt})(?![A-Za-z0-9_\\x80-\\xFF])#{HWS}(?:(?:\\|\\||&&|[+\\-*\\/%&|^]|<<|>>|\\*\\*)=|=(?![=>~])))",
          Regexp::NOENCODING
        )
      end

      def collect_literal_offsets(bytes, needle)
        offsets = []
        pos = 0
        while (idx = bytes.byteindex(needle, pos))
          offsets << idx
          pos = idx + needle.bytesize
        end
        offsets
      end

      def collect_regex_offsets(bytes, regex)
        offsets = []
        pos = 0
        while (idx = bytes.byteindex(regex, pos))
          offsets << idx
          pos = idx + 1
        end
        offsets
      end

      # Shared helper methods mixed into AST visitors.
      module AstHelpers
        def server_only_call?(node)
          node.name == :server_only &&
            (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)) &&
            node.arguments.nil? &&
            node.block.is_a?(Prism::BlockNode)
        end

        # The innermost full constant name for a definition node.
        def defined_name(node, namespace)
          case node
          when Prism::ClassNode, Prism::ModuleNode
            name = AstLowerer.constant_name(node.constant_path)
          when Prism::ConstantWriteNode, Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode, Prism::ConstantOperatorWriteNode
            name = node.name.to_s
          when Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode, Prism::ConstantPathAndWriteNode, Prism::ConstantPathOperatorWriteNode
            name = AstLowerer.constant_name(node.target)
          end
          return unless name

          if name.start_with?("::")
            name.delete_prefix("::")
          elsif namespace.empty?
            name
          else
            "#{namespace.join('::')}::#{name}"
          end
        end

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

        def set_candidate_offsets(offsets)
          if offsets && !offsets.empty?
            @candidate_offsets = offsets
            @cand_min = offsets[0]
            @cand_max = offsets[-1]
            @cand_single = offsets.length == 1
          else
            @candidate_offsets = nil
          end
        end
      end
      private_constant :AstHelpers

      # Shared Prism::Visitor base with leaf no-ops and direct container dispatch
      # so subclasses override only rule-specific hooks without duplicating AST
      # traversal tables.
      class FastVisitor < Prism::Visitor
        include AstHelpers

        # Leaf no-ops
        def visit_string_node(_); end
        def visit_symbol_node(_); end
        def visit_float_node(_); end
        def visit_true_node(_); end
        def visit_false_node(_); end
        def visit_nil_node(_); end
        def visit_self_node(_); end
        def visit_local_variable_read_node(_); end
        def visit_instance_variable_read_node(_); end
        def visit_class_variable_read_node(_); end
        def visit_global_variable_read_node(_); end
        def visit_required_parameter_node(_); end
        def visit_regular_expression_node(_); end

        # Container hot paths (avoid Prism::Visitor#each_child_node array allocation)
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

        def visit_block_parameters_node(node)
          node.parameters&.accept(self)
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
      end
      private_constant :FastVisitor

      # Shared constant-definition scanner with candidate-offset subtree pruning.
      class DefVisitor < FastVisitor
        def visit_integer_node(_); end
        def visit_constant_read_node(_); end

        def visit_def_node(node)
          return if prune_node?(node)

          node.receiver&.accept(self)
          node.parameters&.accept(self)
          node.body&.accept(self)
        end

        def visit_class_node(node)
          return if prune_node?(node)

          name = defined_name(node, @namespace)
          record_named_const(name, node) if name
          outer = @namespace
          @namespace = name ? name.split("::") : outer
          node.body&.accept(self)
          @namespace = outer
        end

        def visit_module_node(node)
          return if prune_node?(node)

          name = defined_name(node, @namespace)
          record_named_const(name, node) if name
          outer = @namespace
          @namespace = name ? name.split("::") : outer
          node.body&.accept(self)
          @namespace = outer
        end

        def visit_constant_write_node(node)
          record_const(node)
          node.value.accept(self)
        end

        def visit_constant_or_write_node(node)
          record_const(node)
          node.value.accept(self)
        end

        def visit_constant_and_write_node(node)
          record_const(node)
          node.value.accept(self)
        end

        def visit_constant_operator_write_node(node)
          record_const(node)
          node.value.accept(self)
        end

        def visit_constant_path_write_node(node)
          record_const(node)
          node.target.accept(self)
          node.value.accept(self)
        end

        def visit_constant_path_or_write_node(node)
          record_const(node)
          node.target.accept(self)
          node.value.accept(self)
        end

        def visit_constant_path_and_write_node(node)
          record_const(node)
          node.target.accept(self)
          node.value.accept(self)
        end

        def visit_constant_path_operator_write_node(node)
          record_const(node)
          node.target.accept(self)
          node.value.accept(self)
        end

        def visit_if_node(node)
          return if prune_node?(node)

          node.predicate.accept(self)
          node.statements&.accept(self)
          node.subsequent&.accept(self)
        end

        def visit_unless_node(node)
          return if prune_node?(node)

          node.predicate.accept(self)
          node.statements&.accept(self)
          node.else_clause&.accept(self)
        end

        def visit_begin_node(node)
          return if prune_node?(node)

          super
        end

        def visit_block_node(node)
          return if prune_node?(node)

          super
        end
      end
      private_constant :DefVisitor

      # Fast Prism::Visitor for collecting constant definitions inside `server_only` blocks.
      class ServerOnlyDefVisitor < DefVisitor
        def initialize(defs)
          @defs = defs
          @rel = nil
          @namespace = []
          @in_server_only = false
          @candidate_offsets = nil
        end

        def scan(rel, root, candidate_offsets)
          @rel = rel
          @namespace = []
          @in_server_only = false
          set_candidate_offsets(candidate_offsets)
          root.accept(self)
        end

        def visit_call_node(node)
          return if prune_node?(node)

          if server_only_call?(node)
            outer = @in_server_only
            @in_server_only = true
            node.block.body&.accept(self)
            @in_server_only = outer
            return
          end

          node.receiver&.accept(self)
          node.arguments&.accept(self)
          node.block&.accept(self)
        end

        private

        def prune_node?(node)
          return false if @in_server_only || !@candidate_offsets

          loc = node.location
          !has_candidate_in?(loc.start_offset, loc.end_offset)
        end

        def record_const(node)
          return unless @in_server_only

          name = defined_name(node, @namespace)
          record_named_const(name, node) if name
        end

        def record_named_const(name, node)
          @defs[name] ||= "#{@rel}:#{node.location.start_line}" if @in_server_only
        end
      end
      private_constant :ServerOnlyDefVisitor

      # Fast Prism::Visitor for collecting client-side definitions matching target constants.
      class ClientDefVisitor < DefVisitor
        def initialize(defs, target_set)
          @defs = defs
          @target_set = target_set
          @namespace = []
          @candidate_offsets = nil
          @has_server_only = false
        end

        def scan(root, candidate_offsets, has_server_only:)
          @namespace = []
          @has_server_only = has_server_only
          set_candidate_offsets(candidate_offsets)
          root.accept(self)
        end

        def visit_call_node(node)
          return if prune_node?(node)
          return if @has_server_only && server_only_call?(node)

          node.receiver&.accept(self)
          node.arguments&.accept(self)
          node.block&.accept(self)
        end

        private

        def prune_node?(node)
          return false unless @candidate_offsets

          loc = node.location
          !has_candidate_in?(loc.start_offset, loc.end_offset)
        end

        def record_const(node)
          name = defined_name(node, @namespace)
          record_named_const(name, node) if name
        end

        def record_named_const(name, _node)
          @defs.add(name) if @target_set.include?(name)
        end
      end
      private_constant :ClientDefVisitor

      # Allocation-minimized Prism::Visitor that checks only the rules active for each file.
      class LintVisitor < FastVisitor
        def initialize(diagnostics, server_only, server_only_leaf_syms)
          @diagnostics = diagnostics
          @server_only = server_only
          @server_only_leaf_syms = server_only_leaf_syms
        end

        def lint_file(rel, root, in_screen_path:, need_int:, need_screen:, need_so:, has_browser:, has_server_only:)
          @rel = rel
          @namespace = []
          @namespace_so_hit = nil
          @in_screen = in_screen_path && need_screen
          @need_int = need_int
          @need_screen = need_screen
          @need_so = need_so
          @track_namespace = need_int || need_so
          @has_browser = has_browser
          @has_server_only = has_server_only
          @const_ints = {}
          @empty_hash_helpers = nil
          @empty_hash_locals = nil
          @reported_int_nodes = nil
          root.accept(self)
        end

        def visit_defined_node(_); end

        # Semantic rule visitors
        def visit_call_node(node)
          return if @has_server_only && server_only_call?(node)

          if @need_int && OVERFLOW_OPS[node.name] && node.block.nil? && int_receiver_candidate?(node.receiver)
            check_int_call(node)
          end
          check_screen_call(node) if @in_screen

          node.receiver&.accept(self)
          node.arguments&.accept(self)
          node.block&.accept(self)
        end

        def visit_integer_node(node)
          return unless @need_int

          val = node.value
          return if val <= INT32_MAX && val >= INT32_MIN
          return if @reported_int_nodes&.include?(node)

          (@reported_int_nodes ||= Set.new.compare_by_identity).add(node)
          report_int_overflow(node, val)
        end

        def visit_if_node(node)
          if @has_browser
            case browser_predicate(node.predicate)
            when true
              node.statements&.accept(self)
              return
            when false
              node.subsequent&.accept(self)
              return
            end
          end

          node.predicate.accept(self)
          node.statements&.accept(self)
          node.subsequent&.accept(self)
        end

        def visit_unless_node(node)
          if @has_browser
            case browser_predicate(node.predicate)
            when true
              node.else_clause&.accept(self)
              return
            when false
              node.statements&.accept(self)
              return
            end
          end

          node.predicate.accept(self)
          node.statements&.accept(self)
          node.else_clause&.accept(self)
        end

        def visit_class_node(node)
          node.superclass&.accept(self)

          if @need_screen
            outer_screen = @in_screen
            outer_helpers = @empty_hash_helpers
            @in_screen ||= screen_superclass?(node.superclass)
            @empty_hash_helpers = @in_screen ? collect_empty_hash_helpers(node) : nil
            walk_namespace(node)
            @in_screen = outer_screen
            @empty_hash_helpers = outer_helpers
          else
            walk_namespace(node)
          end
        end

        def visit_module_node(node)
          walk_namespace(node)
        end

        def visit_def_node(node)
          if @in_screen
            outer_locals = @empty_hash_locals
            @empty_hash_locals = nil
            check_screen_def_params(node.parameters) if node.parameters
            node.parameters&.accept(self)
            node.body&.accept(self)
            @empty_hash_locals = outer_locals
          else
            node.parameters&.accept(self)
            node.body&.accept(self)
          end
        end

        def visit_local_variable_write_node(node)
          track_empty_hash_local(node) if @in_screen
          node.value.accept(self)
        end

        def visit_instance_variable_write_node(node)
          if @in_screen && SCREEN_HASH_IVARS_MAP[node.name] && empty_hash_literal?(node.value)
            report_untyped_hash(node, "#{node.name} = {}")
          end
          node.value.accept(self)
        end

        def visit_constant_write_node(node)
          if @need_int
            value = eval_const_int(node.value)
            if value.is_a?(Integer) && value >= INT32_MIN && value <= INT32_MAX
              name = defined_name(node, @namespace)
              @const_ints[name] = value if name
            end
          end
          node.value.accept(self)
        end

        def visit_constant_path_write_node(node)
          node.target.parent&.accept(self)
          node.value.accept(self)
        end

        def visit_constant_path_or_write_node(node)
          node.target.parent&.accept(self)
          node.value.accept(self)
        end

        def visit_constant_path_and_write_node(node)
          node.target.parent&.accept(self)
          node.value.accept(self)
        end

        def visit_constant_path_operator_write_node(node)
          node.target.parent&.accept(self)
          node.value.accept(self)
        end

        def visit_constant_path_node(node)
          if @need_so
            hit = false
            curr = node
            while curr.is_a?(Prism::ConstantPathNode)
              hit ||= @server_only_leaf_syms[curr.name]
              curr = curr.parent
            end
            if curr.is_a?(Prism::ConstantReadNode)
              hit ||= @server_only_leaf_syms[curr.name]
              check_server_only_const_ref(node) if hit || @namespace_so_hit
            elsif curr.nil?
              check_server_only_const_ref(node) if hit || @namespace_so_hit
            else
              node.parent.accept(self)
            end
          else
            node.parent.accept(self) unless static_constant_path?(node)
          end
        end

        def visit_constant_read_node(node)
          return unless @need_so
          return unless @namespace_so_hit || @server_only_leaf_syms[node.name]

          check_server_only_const_ref(node)
        end

        private

        def static_constant_path?(node)
          curr = node.parent
          while curr
            return true if curr.is_a?(Prism::ConstantReadNode)
            return false unless curr.is_a?(Prism::ConstantPathNode)

            curr = curr.parent
          end
          true
        end

        def walk_namespace(node)
          unless @track_namespace
            node.body&.accept(self)
            return
          end

          outer = @namespace
          outer_so_hit = @namespace_so_hit
          name = defined_name(node, outer)
          if name
            @namespace = name.split("::")
            @namespace_so_hit = @need_so ? (outer_so_hit || matching_server_only_constant(name)) : nil
          end
          node.body&.accept(self)
          @namespace = outer
          @namespace_so_hit = outer_so_hit
        end

        # true or false when the condition is `InstantRecord.browser?` or its
        # negation, nil for any other condition.
        def browser_predicate(node)
          case node
          when Prism::ParenthesesNode
            browser_predicate(only_statement(node))
          when Prism::CallNode
            return unless node.arguments.nil? && node.block.nil?

            case node.name
            when :browser?
              recv = AstLowerer.constant_name(node.receiver)
              true if recv == "InstantRecord" || recv == "::InstantRecord"
            when :!
              inner = browser_predicate(node.receiver)
              inner.nil? ? nil : !inner
            end
          end
        end

        def only_statement(node)
          statements = body_statements(node)
          statements.first if statements.length == 1
        end

        def body_statements(node)
          body = node.body
          body = body.statements if body.is_a?(Prism::BeginNode)
          body.is_a?(Prism::StatementsNode) ? body.body : []
        end

        # --- Rule 1: >31-bit integer literals & constant expressions ---

        def int_receiver_candidate?(node)
          case node
          when Prism::IntegerNode, Prism::CallNode, Prism::ParenthesesNode
            true
          when Prism::ConstantReadNode, Prism::ConstantPathNode
            !@const_ints.empty?
          else
            false
          end
        end

        def check_int_call(node)
          return if @reported_int_nodes&.include?(node)

          args_node = node.arguments
          if args_node.nil?
            lhs = eval_const_int(node.receiver)
            return unless lhs.is_a?(Integer) && lhs >= INT32_MIN && lhs <= INT32_MAX

            value = eval_unary(node.name, lhs)
          else
            args = args_node.arguments
            return unless args.length == 1

            lhs = eval_const_int(node.receiver)
            return unless lhs.is_a?(Integer) && lhs >= INT32_MIN && lhs <= INT32_MAX

            rhs = eval_const_int(args[0])
            return unless rhs.is_a?(Integer) && rhs >= INT32_MIN && rhs <= INT32_MAX

            value = eval_binary(node.name, lhs, rhs)
          end

          return unless overflow?(value)

          mark_subtree_reported(node)
          report_int_overflow(node, value)
        end

        def report_int_overflow(node, value)
          detail = value == :overflow ? "exceeds 32-bit signed integer range" : "evaluates to #{value}, outside 32-bit signed integer range (#{INT32_MIN}..#{INT32_MAX})"
          add_diagnostic(
            rule: :integer_overflow,
            node: node,
            message: "Integer #{node.slice.inspect} #{detail}; compiled wasm32/Spinel builds raise RangeError on >31-bit values."
          )
        end

        def mark_subtree_reported(node)
          (@reported_int_nodes ||= Set.new.compare_by_identity).add(node)
          node.compact_child_nodes.each { |child| mark_subtree_reported(child) }
        end

        def overflow?(value)
          value == :overflow || (value.is_a?(Integer) && (value > INT32_MAX || value < INT32_MIN))
        end

        def eval_const_int(node)
          case node
          when Prism::IntegerNode
            node.value
          when Prism::ParenthesesNode
            eval_const_int(only_statement(node))
          when Prism::ConstantReadNode, Prism::ConstantPathNode
            return if @const_ints.empty?

            find_const_int(node)
          when Prism::CallNode
            return if node.block

            args_node = node.arguments
            if args_node.nil?
              lhs = eval_const_int(node.receiver)
              return :overflow if lhs == :overflow
              return unless lhs.is_a?(Integer)

              eval_unary(node.name, lhs)
            else
              args = args_node.arguments
              return if args.length != 1

              lhs = eval_const_int(node.receiver)
              rhs = eval_const_int(args[0])
              return :overflow if lhs == :overflow || rhs == :overflow
              return unless lhs.is_a?(Integer) && rhs.is_a?(Integer)

              eval_binary(node.name, lhs, rhs)
            end
          end
        end

        def find_const_int(node)
          name = AstLowerer.constant_name(node)
          return unless name

          if name.start_with?("::")
            return @const_ints[name.delete_prefix("::")]
          end
          return @const_ints[name] if @namespace.empty?

          depth = @namespace.length
          while depth > 0
            full = "#{@namespace.first(depth).join('::')}::#{name}"
            return @const_ints[full] if @const_ints.key?(full)

            depth -= 1
          end
          @const_ints[name]
        end

        def eval_unary(name, value)
          case name
          when :-@ then -value
          when :+@ then value
          when :~ then ~value
          else
            multiplier = BYTE_MULTIPLIERS[name]
            value * multiplier if multiplier
          end
        end

        def eval_binary(name, lhs, rhs)
          case name
          when :+ then lhs + rhs
          when :- then lhs - rhs
          when :* then lhs * rhs
          when :/ then lhs / rhs unless rhs == 0
          when :% then lhs % rhs unless rhs == 0
          when :& then lhs & rhs
          when :| then lhs | rhs
          when :^ then lhs ^ rhs
          when :**
            return if rhs < 0

            lhs.abs >= 2 && rhs >= 32 ? :overflow : lhs**rhs
          when :<<
            return if rhs < 0

            lhs != 0 && rhs >= 32 ? :overflow : lhs << rhs
          when :>> then lhs >> rhs unless rhs < 0
          end
        end

        # --- Rule 2: Untyped `{}` hashes in Native::Screen params:/args:/props: ---

        def screen_superclass?(superclass)
          return false unless superclass

          name = AstLowerer.constant_name(superclass)
          return false unless name

          name = name.delete_prefix("::") if name.start_with?("::")
          SCREEN_SUPERCLASSES.key?(name)
        end

        def collect_empty_hash_helpers(class_node)
          helpers = nil
          body_statements(class_node).each do |stmt|
            next unless stmt.is_a?(Prism::DefNode) && stmt.receiver.nil? && stmt.parameters.nil?

            if empty_hash_literal?(only_statement(stmt))
              (helpers ||= Set.new).add(stmt.name)
            end
          end
          helpers
        end

        def track_empty_hash_local(write_node)
          if empty_hash_literal?(write_node.value)
            (@empty_hash_locals ||= Set.new).add(write_node.name)
          else
            @empty_hash_locals&.delete(write_node.name)
          end
        end

        def check_screen_def_params(params)
          params.optionals.each { |param| check_screen_default(param, "#{param.name} = {}") }
          params.keywords.each do |param|
            check_screen_default(param, "#{param.name}: {}") if param.is_a?(Prism::OptionalKeywordParameterNode)
          end
        end

        def check_screen_default(param, snippet)
          return unless SCREEN_HASH_KEYS_MAP[param.name] && empty_hash_literal?(param.value)

          report_untyped_hash(param, snippet)
        end

        def check_screen_call(call_node)
          if @empty_hash_locals && HASH_MUTATION_OPS[call_node.name] && call_node.receiver.is_a?(Prism::LocalVariableReadNode)
            @empty_hash_locals.delete(call_node.receiver.name)
          end

          args_node = call_node.arguments
          return unless args_node

          args = args_node.arguments
          if SCREEN_HASH_SETTERS_MAP[call_node.name]
            report_untyped_hash(args[0], "#{call_node.name} {}") if untyped_hash_expr?(args[0])
            return
          end

          args.each do |arg|
            next unless arg.is_a?(Prism::KeywordHashNode)

            arg.elements.each do |assoc|
              next unless assoc.is_a?(Prism::AssocNode) && assoc.key.is_a?(Prism::SymbolNode)

              key = assoc.key.unescaped.to_sym
              if SCREEN_HASH_KEYS_MAP[key] && untyped_hash_expr?(assoc.value)
                report_untyped_hash(assoc.value, "#{key}: #{assoc.value.slice}")
              end
            end
          end
        end

        def empty_hash_literal?(node)
          case node
          when Prism::HashNode
            node.elements.empty?
          when Prism::CallNode
            node.name == :new &&
              node.arguments.nil? &&
              node.block.nil? &&
              ((recv = AstLowerer.constant_name(node.receiver)) == "Hash" || recv == "::Hash")
          when Prism::ParenthesesNode
            empty_hash_literal?(only_statement(node))
          else
            false
          end
        end

        def untyped_hash_expr?(node)
          return true if empty_hash_literal?(node)

          case node
          when Prism::LocalVariableReadNode
            @empty_hash_locals ? @empty_hash_locals.include?(node.name) : false
          when Prism::CallNode
            node.receiver.nil? && node.arguments.nil? && node.block.nil? &&
              (@empty_hash_helpers ? @empty_hash_helpers.include?(node.name) : false)
          when Prism::IfNode
            untyped_hash_expr?(node.statements) || untyped_hash_expr?(node.subsequent)
          when Prism::UnlessNode
            untyped_hash_expr?(node.statements) || untyped_hash_expr?(node.else_clause)
          when Prism::ElseNode
            untyped_hash_expr?(node.statements)
          when Prism::StatementsNode
            untyped_hash_expr?(node.body.last)
          when Prism::ParenthesesNode
            untyped_hash_expr?(only_statement(node))
          else
            false
          end
        end

        def report_untyped_hash(node, snippet)
          add_diagnostic(
            rule: :untyped_screen_hash,
            node: node,
            message: "Untyped empty hash in Native::Screen (#{snippet}); use InstantRecord::Native::Node.strings so Spinel types it as Hash[String, String]."
          )
        end

        # --- Rule 3: server_only constant references from shared code ---

        def check_server_only_const_ref(node)
          name = AstLowerer.constant_name(node)
          return unless name

          matched = find_matching_server_only_constant(name)
          return unless matched

          defined_at = @server_only[matched]
          origin = defined_at ? " (defined inside server_only at #{defined_at})" : " (server-only gem constant)"
          add_diagnostic(
            rule: :server_only_constant,
            node: node,
            message: "Shared/client code references server_only constant `#{matched}`#{origin}; wrap in `server_only` or define a client counterpart."
          )
        end

        def find_matching_server_only_constant(name)
          if name.start_with?("::")
            return matching_server_only_constant(name.delete_prefix("::"))
          end
          return matching_server_only_constant(name) if @namespace.empty?

          depth = @namespace.length
          while depth > 0
            full = "#{@namespace.first(depth).join('::')}::#{name}"
            matched = matching_server_only_constant(full)
            return matched if matched

            depth -= 1
          end
          matching_server_only_constant(name)
        end

        # The name itself or the closest namespace around it that is server_only:
        # `ServerOnlyClass::SUB` matches `ServerOnlyClass`.
        def matching_server_only_constant(full_name)
          until @server_only.key?(full_name)
            idx = full_name.rindex("::")
            return unless idx

            full_name = full_name.byteslice(0, idx)
          end
          full_name
        end

        def add_diagnostic(rule:, node:, message:)
          loc = node.location
          @diagnostics << Diagnostic.new(
            rule: rule,
            file: @rel,
            line: loc.start_line,
            column: loc.start_column + 1,
            message: message
          )
        end
      end
      private_constant :LintVisitor
    end
  end
end
