require "erb"
require "yaml"

module InstantRecord
  # config/native.yml, as the app is given it. ERB runs first. A mistake
  # raises where the developer sees it and never reaches a phone as a config
  # with a hole: the app keeps the last good one.
  module NativeConfig
    class Invalid < StandardError; end

    def self.load(path = Rails.root.join("config/native.yml"))
      return unless File.exist?(path)

      config = YAML.safe_load(ERB.new(File.read(path)).result, aliases: true, filename: path.to_s)
      check(config)
      config
    end

    def self.check(config)
      raise Invalid, "config/native.yml must list tabs" unless config.is_a?(Hash) && config["tabs"].is_a?(Array) && config["tabs"].any?

      config["tabs"].each do |tab|
        raise Invalid, "Each tab in config/native.yml needs a title and a path that starts with /" unless tab.is_a?(Hash) && tab["title"].is_a?(String) && path?(tab["path"])
      end
      Array(config["routes"]).each do |route|
        kinds = route.is_a?(Hash) ? %w[screen view page].count { |kind| route[kind] } : 0
        raise Invalid, "Each route in config/native.yml needs a path and one of screen, view or page" unless kinds == 1 && path?(route["path"])
      end
    end

    def self.path?(value) = value.is_a?(String) && value.start_with?("/") && !value.start_with?("//")
    private_class_method :path?
  end
end
