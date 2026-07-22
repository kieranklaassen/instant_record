module InstantRecord
  class Engine < ::Rails::Engine
    isolate_namespace InstantRecord

    config.instant_record = ActiveSupport::OrderedOptions.new
    config.instant_record.mount_path = "/instant_record"

    initializer "instant_record.migrations" do |app|
      unless app.root == root
        config.paths["db/migrate"].expanded.each do |path|
          app.config.paths["db/migrate"] << path unless app.config.paths["db/migrate"].include?(path)
        end
      end
    end

    # Auto-mount the sync endpoints on the server. Set
    # `config.instant_record.mount_path = false` to mount manually,
    # or to another string to change the path.
    initializer "instant_record.mount" do |app|
      next if InstantRecord.browser?

      mount_path = app.config.instant_record.mount_path
      next unless mount_path

      app.routes.append do
        mount InstantRecord::Engine => mount_path
      end
    end
  end
end
