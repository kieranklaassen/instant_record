require "rails/generators"

module InstantRecord
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      def self.source_paths
        [source_root, File.expand_path("../../../../compiled", __dir__)]
      end

      def install_toolchain_config
        copy_file "toolchain.env.example", "config/instant_record_toolchain.env"
      end

      def install_initializer
        copy_file "instant_record.rb", "config/initializers/instant_record.rb"
      end

      def show_next_steps
        say <<~MSG

          Next steps for InstantRecord:

            1. Fill in tool paths in config/instant_record_toolchain.env
               (see compiled/README.md for Roundhouse, Spinel, WASI SDK, SQLite, and npm setup).
            2. Include InstantRecord::Syncable in your synced models. Each table needs:
                 id: :string, server_version: :integer (default: 0, null: false),
                 sync_state: :string (default: "synced", null: false)
            3. Run migrations, check your toolchain, and compile:
                 bin/rails db:migrate
                 bin/rails instant_record:doctor
                 bin/rails instant_record:compile

          The browser site is written to tmp/instant_record/compiled/web/dist.
          Review config/initializers/instant_record.rb to configure scoping, file storage, or hosting.
        MSG
      end
    end
  end
end
