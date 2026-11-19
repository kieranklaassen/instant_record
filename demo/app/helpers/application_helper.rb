module ApplicationHelper
  # An Assistant reply as blocks the view can draw: [kind, text] pairs, where
  # kind is "code", "ul", "ol" or "p". Replies are plain paragraphs, "- " and
  # "1. " lists, and fenced code. Plain string work, so the compiled browser
  # runtime formats a reply exactly as Rails does.
  def assistant_blocks(text)
    blocks = []
    text.split("```").each_with_index do |part, index|
      if index.odd?
        # A fence may open with a language name on its own line.
        line_end = part.index("\n")
        part = part[(line_end + 1)..] if line_end && !part[0, line_end].include?(" ")
        blocks << ["code", part.rstrip]
      else
        part.strip.split("\n\n").each do |paragraph|
          lines = paragraph.strip.split("\n")
          next if lines.empty?
          if lines.all? { |line| line.start_with?("- ") }
            blocks << ["ul", lines.map { |line| line[2..] }.join("\n")]
          elsif lines.all? { |line| assistant_numbered?(line) }
            blocks << ["ol", lines.map { |line| line[(line.index(". ") + 2)..] }.join("\n")]
          else
            blocks << ["p", paragraph.strip]
          end
        end
      end
    end
    blocks
  end

  def assistant_numbered?(line)
    dot = line.index(". ")
    !dot.nil? && dot > 0 && line[0, dot].to_i.to_s == line[0, dot]
  end
end
