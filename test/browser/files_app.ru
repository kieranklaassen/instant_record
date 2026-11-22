# A Rails app in one file, for test/browser/files.mjs: the gem's engine, one
# model whose records carry a file, and a page that loads the gem's file store
# as the module it is. Everything it writes goes under FILES_APP_ROOT.
#
#   FILES_APP_ROOT=/tmp/files-app bundle exec puma -p 3220 test/browser/files_app.ru
require "bundler/setup"
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "instant_record"

ROOT = ENV.fetch("FILES_APP_ROOT")
ENV["DATABASE_URL"] = "sqlite3:#{File.join(ROOT, "files_app.sqlite3")}"

class FilesApp < Rails::Application
  config.root = ROOT
  config.load_defaults 8.0
  config.eager_load = false
  config.secret_key_base = "files-app-" * 8
  config.hosts.clear
  config.consider_all_requests_local = true
  config.logger = Logger.new(File.join(ROOT, "rails.log"))
  # The page is not this app's to keep: a browser asks for it again each time.
  config.action_dispatch.default_headers = { "cache-control" => "no-store" }
end

PAGE = <<~HTML
  <!doctype html>
  <meta charset="utf-8">
  <title>Files</title>
  <script type="module">
    import { FileStore, fileStore } from "/frontend/files.js"
    const asked = new URLSearchParams(location.search)
    window.FileStore = FileStore
    window.files = fileStore({
      scope: asked.get("scope") || "", auto: asked.get("auto") === "1",
      ...(asked.get("budget") ? { budget: Number(asked.get("budget")) } : {}),
    })
    window.ready = true
  </script>
HTML

FilesApp.initialize!

ActiveRecord::Migration.suppress_messages do
  ActiveRecord::MigrationContext.new(InstantRecord::Engine.root.join("db/migrate").to_s).migrate
  ActiveRecord::Schema.define do
    create_table :clips, id: :string, if_not_exists: true do |t|
      t.string :title
      t.string :owner
      t.string :filename
      t.string :content_type
      t.bigint :byte_size
      t.integer :server_version, null: false, default: 0
      t.string :sync_state, null: false, default: "synced"
      t.timestamps
    end
  end
end

# A clip is its owner's: the `scope` a sync request carries.
class Clip < ActiveRecord::Base
  include InstantRecord::Syncable
  sync_scope :owner
  sync_file max_size: 300 * 1024 * 1024
end

FilesApp.routes.append do
  mount Rack::Files.new(InstantRecord::Engine.root.join("frontend").to_s) => "/frontend"
  root to: ->(_env) { [200, { "content-type" => "text/html; charset=utf-8" }, [PAGE]] }
end

run FilesApp
