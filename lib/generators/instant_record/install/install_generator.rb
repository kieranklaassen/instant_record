require "rails/generators"

module InstantRecord
  module Generators
    # Prepares a Rails app for InstantRecord's browser runtime:
    # wasmify environment, PGlite database config, and a PWA shell
    # wired with the InstantRecord sync driver.
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      def run_wasmify_install
        rake "wasmify:install"
      end

      def generate_pwa_shell
        rake "wasmify:pwa"
      end

      def configure_pglite_database
        gsub_file "config/database.yml", '{ "nulldb" }', '{ "pglite" }'
        inject_into_file "config/database.yml", "  js_interface: pglite4rails\n",
          after: /^wasm:\n  adapter: .*\n/
      end

      def install_sync_driver
        copy_file "rails.sw.js", "pwa/rails.sw.js", force: true
        copy_file "database.js", "pwa/database.js", force: true
      end

      def use_pglite_in_pwa
        gsub_file "pwa/package.json", /"wasmify-rails": "\^[\d.]+"/, '"wasmify-rails": "^0.2.3"'
        gsub_file "pwa/package.json", %r{"@sqlite\.org/sqlite-wasm": "[^"]+"}, '"@electric-sql/pglite": "^0.3.0"'
        gsub_file "pwa/vite.config.js", %r{exclude: \["@sqlite\.org/sqlite-wasm"\]}, 'exclude: ["@electric-sql/pglite"]'
      end

      def show_next_steps
        say <<~MSG

          InstantRecord is set up. Next:

            1. Mark the gems your app needs in the browser with `group: [:default, :wasm]` in the Gemfile
            2. bin/rails db:migrate                # engine tables (outbox, change log, ...)
            3. bin/rails instant_record:build      # compile + pack the browser bundle
            4. cd pwa && yarn install && yarn dev  # boot it

        MSG
      end
    end
  end
end
