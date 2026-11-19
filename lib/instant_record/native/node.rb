module InstantRecord
  module Native
    # One element of a screen. Every element is this class with these fields,
    # whatever it draws: the compiler that builds the phone app infers one type
    # for a whole tree, and the renderer switches on `kind`.
    #
    # `link_params` are the params of the screen a link opens ("params" in the
    # JSON). The accessor is not called `params`: the compiler types a method
    # by its name across the whole app, and a Rails app already has a `params`
    # that holds anything.
    class Node
      attr_reader :kind, :props, :children
      attr_accessor :id, :text, :action, :link_params, :args

      def initialize(kind)
        @kind = kind
        @id = ""
        @text = ""
        @action = ""
        @link_params = Node.strings
        @args = Node.strings
        @props = Node.strings
        @children = []
      end

      # An empty hash of strings by name. Not `{}`: the phone's compiler types
      # a hash by what it holds, an empty literal holds nothing it can go by,
      # and it would then treat a hash of strings given in its place as
      # another kind of hash.
      def self.strings
        none = { "" => "" }
        none.clear
        none
      end

      def set(name, value)
        @props[name] = value if value.length > 0
      end

      # Written by hand so the compiled app and CRuby produce the same bytes.
      # Not `to_json`: JSON.generate calls that with an argument, and the
      # compiled app's runtime gives every object one of its own.
      def json
        out = +""
        write(out)
        out
      end

      def write(out)
        out << "{\"kind\":" << Node.quote(@kind)
        out << ",\"id\":" << Node.quote(@id)
        out << ",\"text\":" << Node.quote(@text)
        out << ",\"action\":" << Node.quote(@action)
        # Three loops and not one method called three times: the phone's
        # compiler gives each hash the type of what it was handed, and a
        # shared method would have to convert between them.
        out << ",\"params\":{"
        first = true
        @link_params.each do |name, value|
          out << "," unless first
          first = false
          out << Node.quote(name.to_s) << ":" << Node.quote(value.to_s)
        end
        out << "}"
        out << ",\"args\":{"
        first = true
        @args.each do |name, value|
          out << "," unless first
          first = false
          out << Node.quote(name.to_s) << ":" << Node.quote(value.to_s)
        end
        out << "}"
        out << ",\"props\":{"
        first = true
        @props.each do |name, value|
          out << "," unless first
          first = false
          out << Node.quote(name.to_s) << ":" << Node.quote(value.to_s)
        end
        out << "}"
        out << ",\"children\":["
        first = true
        @children.each do |child|
          out << "," unless first
          first = false
          child.write(out)
        end
        out << "]}"
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
