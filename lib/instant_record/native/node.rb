module InstantRecord
  module Native
    # One element of a screen. Every element is this class with these fields,
    # whatever it draws: the compiler that builds the phone app infers one type
    # for a whole tree, and the renderer switches on `kind`.
    class Node
      attr_reader :kind, :props, :children
      attr_accessor :id, :text, :action, :arg

      def initialize(kind)
        @kind = kind
        @id = ""
        @text = ""
        @action = ""
        @arg = ""
        @props = {}
        @children = []
      end

      def set(name, value)
        @props[name] = value if value.length > 0
      end

      # Written by hand so the compiled app and CRuby produce the same bytes.
      def to_json
        out = +"{"
        out << "\"kind\":" << Node.quote(@kind)
        out << ",\"id\":" << Node.quote(@id)
        out << ",\"text\":" << Node.quote(@text)
        out << ",\"action\":" << Node.quote(@action)
        out << ",\"arg\":" << Node.quote(@arg)
        out << ",\"props\":{"
        first = true
        @props.each do |name, value|
          out << "," unless first
          first = false
          out << Node.quote(name) << ":" << Node.quote(value)
        end
        out << "},\"children\":["
        first = true
        @children.each do |child|
          out << "," unless first
          first = false
          out << child.to_json
        end
        out << "]}"
        out
      end

      HEX = "0123456789abcdef".freeze

      def self.quote(value)
        out = +"\""
        value.each_char do |char|
          code = char.ord
          if char == "\""
            out << "\\\""
          elsif char == "\\"
            out << "\\\\"
          elsif char == "\n"
            out << "\\n"
          elsif char == "\r"
            out << "\\r"
          elsif char == "\t"
            out << "\\t"
          elsif code < 32
            out << "\\u00" << HEX[code / 16] << HEX[code % 16]
          else
            out << char
          end
        end
        out << "\""
        out
      end
    end
  end
end
