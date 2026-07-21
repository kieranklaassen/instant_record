module InstantRecord
  class Engine < ::Rails::Engine
    isolate_namespace InstantRecord

    initializer "instant_record.migrations" do |app|
      unless app.root == root
        config.paths["db/migrate"].expanded.each do |path|
          app.config.paths["db/migrate"] << path unless app.config.paths["db/migrate"].include?(path)
        end
      end
    end
  end
end
