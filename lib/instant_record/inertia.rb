module InstantRecord
  # InstantRecord for an Inertia page. Loaded when the app has inertia_rails.
  #
  #   render inertia: "Email/Inbox", live: { mail: MailEntry, thread: MailEntry },
  #     props: { mail: -> { ... }, thread: -> { ... } }
  #
  # `live:` names, for each prop, the synced models it is made from. The page
  # object then carries Inertia's `liveProps`, and the transport in the gem's
  # frontend package (frontend/live.js) has Inertia reload a prop when a
  # record of one of its models changes in the local database.
  module Inertia
    CHANNEL = { name: "instant_record", type: "local" }.freeze
    # A burst of changes becomes one reload. Reads are local, so this is short.
    THROTTLE_MS = 150

    # The `liveProps` of a page object: one event per model, named for it.
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
