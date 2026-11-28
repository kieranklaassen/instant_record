module InstantRecord
  class Compiler
    # Shared contract identifier inflection, nested type naming, and string
    # escaping helpers used by native code generators.
    module CodegenNaming
      ESCAPE_MAP = {
        "\\" => "\\\\",
        "\"" => "\\\"",
        "\n" => "\\n",
        "\r" => "\\r",
        "\t" => "\\t"
      }.freeze
      private_constant :ESCAPE_MAP

      extend self

      def camel_case(name)
        parts = name.to_s.split("_")
        return name.to_s if parts.length <= 1

        parts.first + parts[1..].map { |part| part.empty? ? "" : part[0].upcase + part[1..] }.join
      end

      def pascal_case(name)
        name.to_s.split("_").map { |part| part.empty? ? "" : part[0].upcase + part[1..] }.join
      end

      def singularize(name)
        word = name.to_s
        return "#{word[0..-4]}y" if word.end_with?("ies") && word.length > 3
        return word[0..-3] if word.match?(/(?:ch|sh|x|z|ss)es\z/)
        return "person" if word == "people"
        return "child" if word == "children"
        return word[0..-2] if word.end_with?("s") && !word.end_with?("ss") && word.length > 1

        "#{word}_item"
      end

      def nested_type_name(field)
        return field.type_name if field.type_name

        base = field.many? ? singularize(field.name) : field.name
        pascal_case(base)
      end

      def escape_string(value)
        value.to_s.gsub(/[\\"\n\r\t]/, ESCAPE_MAP)
      end
    end
  end
end
