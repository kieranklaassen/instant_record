module InstantRecord
  module Inertia
    CHANNEL = { name: CHANNEL_NAME, type: CHANNEL_TYPE }.freeze

    # The `liveProps` of a page object: one event per model, named for it.
    # Each entry may be a Model / Array<Model> or a Hash with `models:` (or
    # `model:`) and optional `partitions:` / `throttle:`.
    def self.live_props(models_by_prop)
      models_by_prop.to_h do |prop, spec|
        if spec.is_a?(Hash)
          models = Array(spec[:models] || spec["models"] || spec[:model] || spec["model"])
          events = models.map { |model| model.respond_to?(:name) ? model.name : model.to_s }
          partitions = spec[:partitions] || spec["partitions"]
          channel = partitions ? CHANNEL.merge(partitions: normalize_partitions(partitions)) : CHANNEL
          throttle = spec[:throttle] || spec["throttle"] || THROTTLE_MS
          [prop.to_sym, { listeners: [{ channel: channel, events: events }], throttle: throttle }]
        else
          events = Array(spec).map { |model| model.respond_to?(:name) ? model.name : model.to_s }
          [prop.to_sym, { listeners: [{ channel: CHANNEL, events: events }], throttle: THROTTLE_MS }]
        end
      end
    end

    def self.normalize_partitions(partitions)
      partitions.to_h do |col, val|
        values = Array(val).compact.map(&:to_s).uniq
        [col.to_s, values]
      end
    end

    # inertia_rails has no word for live props yet, so this adds the key to
    # the page object its renderer builds, and records read tables/models.
    module Renderer
      def initialize(component, controller, request, response, render_method, **options)
        @instant_record_live = options[:live]
        super
      end

      private

      def build_page
        page, reads = InstantRecord::ReadTracker.capture { super }
        if @response && reads && (!reads["tables"].empty? || !reads["models"].empty?)
          @response.set_header("X-Instant-Record-Reads", InstantRecord::ReadTracker.serialize(reads))
        end
        return page if @instant_record_live.blank?

        page.merge(liveProps: InstantRecord::Inertia.live_props(@instant_record_live))
      end
    end
  end
end
