require "instant_record/version"
require "wasmify-rails" # browser build tasks + PGlite adapter; inert outside wasm builds
require "instant_record/engine" if defined?(Rails::Engine)

module InstantRecord
  class << self
    # True when running inside the browser (ruby.wasm).
    def browser?
      RUBY_PLATFORM.include?("wasm")
    end

    # Optional explicit allowlist of syncable models. Without it, any model
    # that includes InstantRecord::Syncable is syncable.
    def sync(*models)
      @synced_models = models.flatten
    end

    def synced_models
      @synced_models ||= []
    end

    def synced_model(record_type)
      return synced_models.find { |model| model.name == record_type } if synced_models.any?

      klass = record_type.to_s.safe_constantize
      klass if klass.respond_to?(:instant_record_syncable?) && klass.instant_record_syncable?
    end
  end
end

ActiveSupport.on_load(:active_record) do
  require "instant_record/syncable"
  require "instant_record/outbox_mutation"
  require "instant_record/sync_metadata"
  require "instant_record/client"
end
