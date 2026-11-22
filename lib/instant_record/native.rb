require "instant_record/native/node"
require "instant_record/native/screen"

module InstantRecord
  # Screens of a native app, written in Ruby (InstantRecord::Native::Screen).
  module Native
    # The screen a name stands for: "mailbox" is MailboxScreen. The compiled
    # app has no constant lookup, so its build writes this out as a `case`
    # from `class_name`.
    def self.screen(name, params = {})
      found = screens.find { |screen| screen_name(screen) == name }
      raise ArgumentError, "No screen named #{name}" unless found
      found.new(params)
    end

    def self.screens(base = Screen)
      base.subclasses.flat_map { |screen| [screen] + screens(screen) }
    end

    def self.screen_name(screen)
      underscore(screen.name.to_s.split("::").last.to_s.delete_suffix("Screen"))
    end

    # The class a screen's file holds: two_words_screen.rb holds
    # TwoWordsScreen. The compiled build asks this for each file in
    # app/screens (InstantRecord::Compiler::EntryBuilder), so the rule that
    # names a screen is written in this file alone.
    def self.class_name(name)
      camel = name.split("_").map(&:capitalize).join
      unless name.match?(/\A[a-z][a-z0-9_]*\z/) && underscore(camel) == name
        raise ArgumentError, "Name each file in app/screens <name>_screen.rb, in lower case with single underscores between words that start with a letter: #{name}"
      end
      "#{camel}Screen"
    end

    def self.underscore(camel)
      camel.gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase
    end
  end
end
