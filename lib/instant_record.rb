require "instant_record/version"
require "instant_record/engine" if defined?(Rails::Engine)

module InstantRecord
  class << self
    # Server-side registration: the allowlist of models the engine will sync.
    def sync(*models)
      @synced_models = models.flatten
    end

    def synced_models
      @synced_models ||= []
    end

    def synced_model(record_type)
      synced_models.find { |model| model.name == record_type }
    end
  end
end
