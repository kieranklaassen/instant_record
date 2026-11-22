module InstantRecord
  # InstantRecord for an Inertia page, shared by Rails and the compiled WASI/Spinel runtime.
  #
  #   page = InstantRecord::Inertia::Page.for_request("Email/Inbox", request)
  #   page.string("member", @member)
  #   page.strings("inboxes", @inboxes)
  #   page.bool("composing", params[:compose] == "1")
  #   page.live("mail", "MailEntry") { JSON.generate(mail_props) }
  #   page.live("thread", "MailEntry") { JSON.generate(thread_props) }
  #
  # Props are serialized as JSON text into parallel String arrays rather than a
  # polymorphic Ruby Hash, and lazy/live props use Ruby blocks rather than Procs
  # inside a Hash, so Roundhouse and Spinel keep strict concrete types.
  module Inertia
    CHANNEL_NAME = "instant_record".freeze
    CHANNEL_TYPE = "local".freeze
    # A burst of changes becomes one reload. Reads are local, so this is short.
    THROTTLE_MS = 150

    class Page
      HEX = "0123456789abcdef".freeze

      attr_reader :component, :url, :version

      def self.for_request(component, request, version: "")
        if request.nil?
          return new(component, "/", false, "", "", "", version)
        end

        req_headers = request.headers
        new(
          component,
          request.fullpath.to_s,
          !req_headers["X-Inertia"].to_s.empty?,
          req_headers["X-Inertia-Partial-Component"].to_s,
          req_headers["X-Inertia-Partial-Data"].to_s,
          req_headers["X-Inertia-Partial-Except"].to_s,
          version
        )
      end

      def self.header_list(value)
        out = []
        parts = value.split(",")
        i = 0
        while i < parts.length
          part = parts[i].strip
          out << part unless part.empty?
          i += 1
        end
        out
      end

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

      def self.json_strings(values)
        out = +"["
        i = 0
        while i < values.length
          out << "," if i > 0
          out << quote(values[i])
          i += 1
        end
        out << "]"
        out
      end

      def initialize(component, url, inertia, partial_component, partial_data, partial_except, version = "")
        @component = component
        @url = url
        @version = version
        @inertia = inertia
        @only = Page.header_list(partial_data)
        @except = Page.header_list(partial_except)
        @partial = inertia && partial_component == component
        @prop_keys = ["errors"]
        @prop_values = ["{}"]
        @live_keys = []
        @live_values = []
      end

      def inertia?
        @inertia
      end

      def partial?
        @partial
      end

      def want?(name)
        !@partial || ((@only.empty? || @only.include?(name)) && !@except.include?(name))
      end

      def string(name, value)
        put_json(name, Page.quote(value)) if want?(name)
        nil
      end

      def int(name, value)
        put_json(name, value.to_s) if want?(name)
        nil
      end

      def bool(name, value)
        put_json(name, value ? "true" : "false") if want?(name)
        nil
      end

      def strings(name, values)
        put_json(name, Page.json_strings(values)) if want?(name)
        nil
      end

      def raw(name, encoded)
        put_json(name, encoded) if want?(name)
        nil
      end

      def always_raw(name, encoded)
        put_json(name, encoded)
        nil
      end

      def lazy(name)
        put_json(name, yield) if want?(name)
        nil
      end

      def live(name, event)
        register_live(name, [event])
        put_json(name, yield) if want?(name)
        nil
      end

      def live_many(name, events)
        register_live(name, events)
        put_json(name, yield) if want?(name)
        nil
      end

      # Written by hand so CRuby and the compiled runtime emit identical JSON.
      def json
        out = +"{\"component\":"
        out << Page.quote(@component)
        out << ",\"props\":{"
        i = 0
        while i < @prop_keys.length
          out << "," if i > 0
          out << Page.quote(@prop_keys[i]) << ":" << @prop_values[i]
          i += 1
        end
        out << "},\"url\":" << Page.quote(@url)
        out << ",\"version\":" << Page.quote(@version)
        unless @live_keys.empty?
          out << ",\"liveProps\":{"
          i = 0
          while i < @live_keys.length
            out << "," if i > 0
            out << Page.quote(@live_keys[i]) << ":" << @live_values[i]
            i += 1
          end
          out << "}"
        end
        out << "}"
        out
      end

      private

      def put_json(name, encoded)
        i = @prop_keys.index(name)
        if i.nil?
          @prop_keys << name
          @prop_values << encoded
        else
          @prop_values[i] = encoded
        end
        nil
      end

      def register_live(name, events)
        entry = +"{\"listeners\":[{\"channel\":{\"name\":"
        entry << Page.quote(CHANNEL_NAME)
        entry << ",\"type\":" << Page.quote(CHANNEL_TYPE)
        entry << "},\"events\":" << Page.json_strings(events)
        entry << "}],\"throttle\":" << THROTTLE_MS.to_s << "}"
        i = @live_keys.index(name)
        if i.nil?
          @live_keys << name
          @live_values << entry
        else
          @live_values[i] = entry
        end
        nil
      end
    end
  end
end

require "instant_record/inertia/renderer"
