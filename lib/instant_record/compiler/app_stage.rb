require "fileutils"
require "pathname"
require_relative "runner"

module InstantRecord
  class Compiler
    module FileCopy
      module_function

      def copy_tree(source, target, ignore: [])
        source_path = Pathname(source)
        target_path = Pathname(target)
        FileUtils.mkdir_p(target_path)

        source_path.children.each do |entry|
          name = entry.basename.to_s
          next if ignore.include?(name)

          dest = target_path.join(name)
          if entry.directory? && !entry.symlink?
            copy_tree(entry, dest, ignore: ignore)
          else
            FileUtils.cp(entry, dest)
          end
        end
      end
    end

    # Stage a consumer Rails app for Roundhouse without touching the original checkout.
    module AppStage
      FOLDERS = %w[
        app/controllers app/models app/views app/helpers app/assets app/javascript
        config/routes config/locales
      ].freeze

      FILES = %w[
        Gemfile config/application.rb config/routes.rb config/importmap.rb db/schema.rb
      ].freeze

      module_function

      def stage(source:, target:, native: false)
        source_path = Pathname(source)
        target_path = Pathname(target)
        FileUtils.rm_rf(target_path)
        FileUtils.mkdir_p(target_path)

        folders = native ? FOLDERS + ["app/screens"] : FOLDERS
        folders.each do |rel|
          dir = source_path.join(rel)
          FileCopy.copy_tree(dir, target_path.join(rel)) if dir.directory?
        end

        FILES.each do |rel|
          path = source_path.join(rel)
          next unless path.file?

          dest = target_path.join(rel)
          FileUtils.mkdir_p(dest.dirname)
          FileUtils.cp(path, dest)
        end

        unless target_path.join("db/schema.rb").file?
          raise BuildError, "The compiled app needs db/schema.rb. Run bin/rails db:migrate and db:schema:dump first."
        end
      end
    end

    # Prepare the demo Rails app for the compiled browser or native runtime.
    module DemoCarver
      IGNORE_PATTERNS = %w[log tmp pwa node_modules storage .bundle].freeze

      # Files and directories that belong strictly to the Rails server and must
      # never be compiled into the browser/native artifact.
      REMOVE = [
        # Browser dependencies come from the compiled runtime. The server's lockfile
        # would also bring Rack's request throttling middleware into the Wasm build.
        "Gemfile.lock", "config/initializers/rack_attack.rb",
        # The compiled worker gets its endpoint from SYNC_ENDPOINT.
        "config/initializers/instant_record.rb",
        # The Inbox speaks Inertia's protocol itself in the browser (its controller's
        # browser_only half); the gem's setup stays on the server.
        "config/initializers/inertia_rails.rb", "app/views/inertia.html.erb",
        "app/controllers/source_controller.rb",
        # RubyLLM answers on the server only: its setup, the reply and the job that asks for
        # one stay there. The browser asks its own model and saves the answer as a record.
        "config/initializers/ruby_llm.rb", "app/models/assistant", "app/jobs/assistant",
        # The session is the server's: the page asks Rails for it over the network.
        "app/controllers/auth/sessions_controller.rb",
        "app/controllers/slack/resets_controller.rb", "app/controllers/email/sync_controller.rb", "app/models/mailbox.rb",
        # The shell snapshot is built on the server, from the server's Mailbox.
        "app/models/mail_shell.rb", "app/jobs/email/shell_build_job.rb",
        "app/views/source", "app/views/pwa",
        "app/helpers/source_helper.rb",
        "test", "db/v2_migrate", "db/seeds.rb", "config/routes", "script", "lib/tasks"
      ].freeze

      DEMO_ROUTES = <<~RUBY
        Rails.application.routes.draw do
          namespace :todo do
            resources :issues, only: [:create, :update, :destroy]
            root "issues#index" # /todo
          end

          namespace :slack do
            resources :channels, only: [:show]
            resources :messages, only: [:create]
            root "channels#index" # /slack
          end

          namespace :migrate do
            root "notes#index"
            resources :notes, only: [:create]
            post "ship", to: "releases#create"
            delete "ship", to: "releases#destroy"
          end
          namespace :assistant do
            resources :turns, only: [:create, :update]
            root "turns#index" # /assistant
          end
          namespace :auth do
            resources :notes, only: [:create, :destroy]
            root "notes#index" # /auth
          end
          get "email", to: "email/mailboxes#index"
          post "email", to: "email/mailboxes#create"
          namespace :console do
            root "sessions#index"
          end
          get "receipts", to: "receipts#index", as: :receipts
          get "receipts/probe", to: "receipts#probe", as: :receipts_probe
          get "home", to: "home#index"
          root "home#index"
        end
      RUBY

      module_function

      def carve(gem_src:, target:, overlay_dir:, native: false)
        demo_dir = File.join(gem_src, "demo")
        FileUtils.rm_rf(target)
        FileCopy.copy_tree(demo_dir, target, ignore: IGNORE_PATTERNS)

        remove_list = native ? REMOVE : REMOVE + ["app/screens"]
        remove_list.each do |rel|
          path = File.join(target, rel)
          FileUtils.rm_rf(path) if File.exist?(path) || File.symlink?(path)
        end

        File.write(File.join(target, "config/routes.rb"), DEMO_ROUTES)

        # Views and model seams specific to the SQLite reactor.
        FileCopy.copy_tree(overlay_dir, File.join(target, "app"))

        adapt_migration_view(target)
        trim_slack_seeds(target)
        enable_mail_entry_sync(target)
      end

      def adapt_migration_view(target)
        path = File.join(target, "app/views/migrate/notes/index.html.erb")
        source = File.read(path)
        source = source.gsub("local Postgres", "local SQLite database")
        source = source.gsub("turbo: false", "turbo: true")
        source = source.gsub("<% has_word_count = @columns.include?(Release::COLUMN) %>", "")
        source = source.gsub("<% if has_word_count %>", "<% unless @release_pending %>")
        source = source.gsub(
          "a\n        migration-local model with <code>update_columns</code>, so nothing\n        queues",
          "a direct SQLite update in the same transaction"
        )
        source = source.gsub(
          "The\n          migration is an <code>add_column</code> inside <code>change</code>, so\n          this is its real reversal — not a separate undo written by hand.",
          "Rollback uses <code>ALTER TABLE</code> and removes the local migration version."
        )
        File.write(path, source)
      end

      def trim_slack_seeds(target)
        path = File.join(target, "app/models/slack/seeds.rb")
        source = File.read(path)
        cut = source.index("    module_function")
        raise BuildError, "Expected module_function marker in #{path}" unless cut

        trimmed = source[0...cut] +
          "    # Browser build: the seeding routines (apply, backfill) are server-only and left out;\n" \
          "    # the constants above are what the browser-side controller reads.\n  end\nend\n"
        File.write(path, trimmed)
      end

      def enable_mail_entry_sync(target)
        path = File.join(target, "app/models/mail_entry.rb")
        source = File.read(path)
        adapted = source.gsub("class MailEntry < ApplicationRecord", "class MailEntry < ApplicationRecord\n  include InstantRecord::Syncable")
        File.write(path, adapted)
      end
    end
  end
end
