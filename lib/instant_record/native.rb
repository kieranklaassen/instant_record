require "instant_record/native/node"
require "instant_record/native/screen"

module InstantRecord
  # Screens of a native app, written in Ruby (InstantRecord::Native::Screen).
  module Native
    # The screen a name stands for: "mailbox" is MailboxScreen. The compiled
    # app has no constant lookup, so its build writes this out as a `case`.
    def self.screen(name, params = {})
      found = screens.find { |screen| screen_name(screen) == name }
      raise ArgumentError, "No screen named #{name}" unless found
      found.new(params)
    end

    def self.screens(base = Screen)
      base.subclasses.flat_map { |screen| [screen] + screens(screen) }
    end

    def self.screen_name(screen)
      name_of(screen.name.to_s)
    end

    # The one rule for a screen's name: OrderLinesScreen is "order_lines".
    # The native build asks this file for it too (make_native_entry.py).
    def self.name_of(class_name)
      class_name.split("::").last.to_s.delete_suffix("Screen").gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase
    end
  end
end
