module InstantRecord
  # Runtime-specific host adapter. On the Rails server this provides CRuby
  # reflection, Rails engine boot, and default channel helpers; AOT builds swap
  # this file with a target-specific adapter from Compiler::HostAdapters instead
  # of patching gem Ruby source with literal string edits.
  module Host
    module_function

    def browser? = false

    def load_engine
      require "instant_record/engine" if defined?(Rails::Engine)
    end

    def load_inertia_renderer
      require "instant_record/inertia/renderer"
    end

    def load_branch_store
      require "instant_record/branch/sqlite_store"
    end

    def install_active_job_guard
      ActiveSupport.on_load(:active_job) do
        require "instant_record/sync_actions"
        InstantRecord::SyncActions.install_active_job_guard!
      end
    end

    def with_savepoint(&block)
      ActiveRecord::Base.transaction(requires_new: true, &block)
    end

    def default_mount_path
      configured =
        if defined?(Rails) && Rails.application && Rails.application.config.respond_to?(:instant_record)
          Rails.application.config.instant_record.mount_path
        end
      configured.is_a?(String) ? configured : InstantRecord::DEFAULT_MOUNT_PATH
    end

    def resolve_syncable_model(record_type)
      klass = record_type.to_s.safe_constantize
      klass if klass.respond_to?(:instant_record_syncable?) && klass.instant_record_syncable?
    end

    def discover_syncable_models
      ActiveRecord::Base.descendants.select do |model|
        !model.abstract_class? && model.name &&
          model.respond_to?(:instant_record_syncable?) && model.instant_record_syncable?
      end
    end

    def blank_id?(id)
      id.nil? || id == ""
    end

    def read_channel(name)
      File.read("/host/#{name}")
    end

    def write_channel(name, body)
      File.write("/host/#{name}", body)
    end
  end
end
