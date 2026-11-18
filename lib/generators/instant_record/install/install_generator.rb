require "rails/generators"

module InstantRecord
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("../../../../compiled", __dir__)

      def install_toolchain_config
        copy_file "toolchain.env.example", "config/instant_record_toolchain.env"
      end

      def show_next_steps
        say <<~MSG
          Set the paths in config/instant_record_toolchain.env.
          Include InstantRecord::Syncable in your synced models, then run:

            bin/rails db:migrate
            bin/rails instant_record:compile

          The browser site is in tmp/instant_record/compiled/web/dist.
          See the gem's compiled/README.md for toolchain setup and deployment.
        MSG
      end
    end
  end
end
