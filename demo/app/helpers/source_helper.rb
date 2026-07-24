# Which lines of a source file are there because of InstantRecord, and how each
# line is coloured. The drawer marks the InstantRecord lines so the ratio is
# visible on the page: every unmarked line is ordinary Rails, and there are a lot
# more of those.
module SourceHelper
  # `InstantRecord` followed by a `.` or `::`, so the brand name in a page title
  # ("Todo — InstantRecord") isn't counted as code.
  INSTANT_RECORD_LINE = /InstantRecord[.:]|\b(?:server_only|browser_only|sync_window|sync_state|pending_count|on_discarded_change)\b/

  def instant_record_line?(line)
    INSTANT_RECORD_LINE.match?(line)
  end

  # One span-marked HTML line per source line, in the same order.
  #
  # Lexed as a whole file rather than line by line, because a string, comment or
  # heredoc that spans lines is only correct in the context of the ones before
  # it. Tokens are then split on newlines so the result still lines up 1:1 with
  # the file — a multi-line token simply gets one span per line it covers, which
  # is also what keeps each line independently wrappable in the drawer.
  def highlighted_lines(lines, path)
    formatter = Rouge::Formatters::HTML.new
    html = [+""]

    lexer_for(path).lex(lines.join("\n")).each do |token, value|
      value.split("\n", -1).each_with_index do |part, index|
        html << +"" unless index.zero?
        html.last << formatter.span(token, part) unless part.empty?
      end
    end

    # `join("\n")` above dropped the trailing newline `readlines` implies, so a
    # final empty element is an artifact rather than a line of the file.
    html.pop if html.size > lines.size && html.last.empty?
    html.map { |line| line.html_safe } # rubocop:disable Rails/OutputSafety
  end

  private

  # Only Ruby and ERB reach the drawer, and both are named by extension, so ask
  # for them directly instead of guessing (which is ambiguous for `.rb` against
  # several dialects). Anything else renders unhighlighted rather than wrongly.
  def lexer_for(path)
    case File.extname(path)
    when ".rb" then Rouge::Lexers::Ruby.new
    when ".erb" then Rouge::Lexers::ERB.new
    else Rouge::Lexers::PlainText.new
    end
  end
end
