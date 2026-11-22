module InstantRecord
  module Inertia
    CHANNEL = { name: CHANNEL_NAME, type: CHANNEL_TYPE }.freeze

    # The `liveProps` of a page object: one event per model, named for it.
    # Used by the server-side inertia_rails adapter below.
    def self.live_props(models_by_prop)
      models_by_prop.to_h do |prop, models|
        events = Array(models).map { |model| model.respond_to?(:name) ? model.name : model.to_s }
        [prop.to_sym, { listeners: [{ channel: CHANNEL, events: events }], throttle: THROTTLE_MS }]
      end
    end

    # inertia_rails has no word for live props yet, so this adds the key to
    # the page object its renderer builds.
    module Renderer
      def initialize(component, controller, request, response, render_method, **options)
        @instant_record_live = options[:live]
        super
      end

      private

      def build_page
        page = super
        return page if @instant_record_live.blank?

        page.merge(liveProps: InstantRecord::Inertia.live_props(@instant_record_live))
      end
    end
  end
end
