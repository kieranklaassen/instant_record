require "test_helper"
require "action_controller"
require "instant_record/routing"
require "instant_record/compiler"
require "fileutils"
require "json"
require "tmpdir"

class LocalFirstIslandsTest < ActiveSupport::TestCase
  GEM_ROOT = File.expand_path("..", __dir__)
  PIPELINE_DIR = File.join(GEM_ROOT, "compiled/pipeline")

  test "local_first route DSL yields transparently on ActionDispatch::Routing::Mapper" do
    route_set = ActionDispatch::Routing::RouteSet.new
    route_set.draw do
      local_first(:tasks, include: { models: ["SubTask"] }, server_routes: ["GET /health"]) do
        namespace :todo do
          resources :issues, only: [:index, :create]
          root "issues#index"
        end
      end
      get "/billing", to: "billing#index"
    end

    assert_equal "/todo", route_set.url_helpers.todo_root_path
    assert_equal "/todo/issues", route_set.url_helpers.todo_issues_path
    assert_equal "/billing", route_set.url_helpers.billing_path

    drawn = route_set.routes.map { |r| [r.verb, r.path.spec.to_s, r.defaults] }
    assert_includes drawn, ["GET", "/todo(.:format)", { controller: "todo/issues", action: "index" }]
    assert_includes drawn, ["POST", "/todo/issues(.:format)", { controller: "todo/issues", action: "create" }]
    assert_includes drawn, ["GET", "/billing(.:format)", { controller: "billing", action: "index" }]
  end

  test "compiles a single route subtree from a monolith and skips unrelated models, controllers, views, helpers, and migrations" do
    Dir.mktmpdir do |dir|
      app_root = File.join(dir, "monolith")
      build_monolith_fixture(app_root)

      staged_dir = File.join(dir, "staged")
      manifest_path = File.join(dir, "instant_record.manifest.json")
      result = InstantRecord::Compiler::AppStage.stage(
        source: app_root,
        target: staged_dir,
        manifest_path: manifest_path
      )
      manifest = result.manifest

      assert_equal "island", manifest.mode
      assert_equal %w[Comment Task], manifest.synced_model_names
      assert_equal({ "limit" => 25, "partition_by" => "task_id" }, manifest.sync_windows["Comment"])
      assert_equal({ "column" => "workspace_id", "policy" => false }, manifest.sync_scopes["Task"])

      # Staged files include only reachable island files.
      assert File.file?(File.join(staged_dir, "app/controllers/application_controller.rb"))
      assert File.file?(File.join(staged_dir, "app/controllers/tasks_controller.rb"))
      assert File.file?(File.join(staged_dir, "app/models/application_record.rb"))
      assert File.file?(File.join(staged_dir, "app/models/task.rb"))
      assert File.file?(File.join(staged_dir, "app/models/comment.rb"))
      assert File.file?(File.join(staged_dir, "app/models/concerns/taggable.rb"))
      assert File.file?(File.join(staged_dir, "app/views/tasks/index.html.erb"))
      assert File.file?(File.join(staged_dir, "app/views/tasks/_row.html.erb"))
      assert File.file?(File.join(staged_dir, "app/views/shared/_badge.html.erb"))
      assert File.file?(File.join(staged_dir, "app/helpers/tasks_helper.rb"))
      assert File.file?(File.join(staged_dir, "app/helpers/badge_helper.rb"))

      # Unrelated monolith billing/admin files are NOT staged.
      refute File.exist?(File.join(staged_dir, "app/controllers/billing/invoices_controller.rb"))
      refute File.exist?(File.join(staged_dir, "app/models/invoice.rb"))
      refute File.exist?(File.join(staged_dir, "app/models/stripe_customer.rb"))
      refute File.exist?(File.join(staged_dir, "app/views/billing/invoices/index.html.erb"))
      refute File.exist?(File.join(staged_dir, "app/helpers/billing_helper.rb"))
      refute File.exist?(File.join(staged_dir, "app/services/stripe_client.rb"))
      refute File.exist?(File.join(staged_dir, "app/jobs/invoice_pdf_job.rb"))

      # Rewritten config/routes.rb keeps only the local_first island routes.
      rewritten_routes = File.read(File.join(staged_dir, "config/routes.rb"))
      assert_includes rewritten_routes, "resources :tasks"
      refute_includes rewritten_routes, "local_first"
      refute_includes rewritten_routes, "invoices"
      assert Prism.parse(rewritten_routes).success?, "Rewritten routes.rb must be valid Ruby"

      # Manifest partitions local vs server routes accurately.
      local_paths = manifest.local_routes.map { |r| [r["method"], r["path"]] }
      server_paths = manifest.server_routes.map { |r| [r["method"], r["path"]] }
      assert_includes local_paths, ["GET", "/tasks"]
      assert_includes local_paths, ["POST", "/tasks"]
      assert_includes server_paths, ["GET", "/billing/invoices"]
      assert_includes server_paths, ["POST", "/billing/webhooks"]

      # Reachable migrations exclude the Postgres-only billing migration so BrowserMigrations succeeds!
      assert_equal [
        "db/migrate/20261120000001_create_tasks.rb",
        "db/migrate/20261120000002_create_comments.rb"
      ], manifest.staged["migrations"]

      plan = InstantRecord::Compiler::BrowserMigrations.plan(
        root: app_root,
        only_files: result.trace.migrations
      )
      assert_equal %w[20261120000001 20261120000002], plan["migrations"].keys
    end
  end

  test "supports named islands, STI and computed-partial include overrides via routes DSL and config/instant_record.yml" do
    Dir.mktmpdir do |dir|
      app_root = File.join(dir, "monolith")
      build_monolith_fixture(app_root)

      # Add STI subclass and a dynamically rendered partial + a second named island.
      File.write(File.join(app_root, "app/models/urgent_task.rb"), <<~RUBY)
        class UrgentTask < Task
        end
      RUBY
      File.write(File.join(app_root, "app/views/tasks/_dynamic_card.html.erb"), "<div>card</div>\n")
      File.write(File.join(app_root, "app/views/tasks/index.html.erb"), <<~ERB)
        <% @tasks.each do |task| %>
          <%= render partial: "row" %>
          <%= render partial: task.card_partial %>
        <% end %>
      ERB
      File.write(File.join(app_root, "config/routes.rb"), <<~RUBY)
        Rails.application.routes.draw do
          local_first(:tasks, include: { partials: ["tasks/dynamic_card"] }) do
            resources :tasks, only: [:index, :create]
          end

          local_first(:billing) do
            namespace :billing do
              resources :invoices, only: [:index]
            end
          end
        end
      RUBY

      # Without STI override, tracer warns about UrgentTask subclass and dynamic partial.
      without_sti = InstantRecord::Compiler::AppStage.analyze(source: app_root, island: :tasks)
      assert_equal "tasks", without_sti.manifest.island
      refute_includes without_sti.trace.models, "app/models/urgent_task.rb"
      assert_includes without_sti.trace.views, "app/views/tasks/_dynamic_card.html.erb"
      assert_any_diagnostic(without_sti.manifest.diagnostics, kind: "sti_subclass", match: /UrgentTask/)
      assert_any_diagnostic(without_sti.manifest.diagnostics, kind: "render", match: /Dynamic partial render/)

      # With config/instant_record.yml island override, UrgentTask is staged cleanly and warning clears.
      File.write(File.join(app_root, "config/instant_record.yml"), <<~YAML)
        islands:
          tasks:
            include:
              models:
                - UrgentTask
            server_routes:
              - POST /tasks/export
      YAML

      with_sti = InstantRecord::Compiler::AppStage.analyze(source: app_root, island: :tasks)
      assert_includes with_sti.trace.models, "app/models/urgent_task.rb"
      refute with_sti.manifest.diagnostics.any? { |d| d["kind"] == "sti_subclass" }
      assert_includes with_sti.manifest.server_routes.map { |r| [r["method"], r["path"]] }, ["POST", "/tasks/export"]
      assert_includes with_sti.manifest.server_routes.map { |r| [r["method"], r["path"]] }, ["GET", "/billing/invoices"]

      # Unknown island raises a crisp diagnostic listing declared islands.
      error = assert_raises(InstantRecord::Compiler::BuildError) do
        InstantRecord::Compiler::AppStage.analyze(source: app_root, island: :nonexistent)
      end
      assert_match(/Unknown local_first island "nonexistent"/, error.message)
      assert_match(/billing, tasks/, error.message)
    end
  end

  test "raises crisp missing-symbol diagnostics for unstaged services, missing controllers, missing partials, and invalid overrides" do
    Dir.mktmpdir do |dir|
      app_root = File.join(dir, "monolith")
      build_monolith_fixture(app_root)

      # 1. Reference to unstaged app/services/stripe_client.rb outside server_only.
      File.write(File.join(app_root, "app/controllers/tasks_controller.rb"), <<~RUBY)
        class TasksController < ApplicationController
          def index
            @tasks = Task.all
            StripeClient.ping
          end
        end
      RUBY

      err = assert_raises(InstantRecord::Compiler::BuildError) do
        InstantRecord::Compiler::AppStage.analyze(source: app_root)
      end
      assert_match(/Missing symbol StripeClient referenced at app\/controllers\/tasks_controller\.rb:4/, err.message)
      assert_match(/app\/services\/stripe_client\.rb/, err.message)
      assert_match(/server_only do/, err.message)

      # 2. Missing partial rendered from view.
      File.write(File.join(app_root, "app/controllers/tasks_controller.rb"), <<~RUBY)
        class TasksController < ApplicationController
          def index
            @tasks = Task.all
          end
        end
      RUBY
      File.write(File.join(app_root, "app/views/tasks/index.html.erb"), '<%= render "does_not_exist" %>')

      err = assert_raises(InstantRecord::Compiler::BuildError) do
        InstantRecord::Compiler::AppStage.analyze(source: app_root)
      end
      assert_match(/Missing partial "does_not_exist" rendered at app\/views\/tasks\/index\.html\.erb:1/, err.message)

      # 3. Missing route controller.
      File.write(File.join(app_root, "app/views/tasks/index.html.erb"), '<%= render "row" %>')
      File.write(File.join(app_root, "config/routes.rb"), <<~RUBY)
        Rails.application.routes.draw do
          local_first do
            get "/ghost", to: "ghosts#index"
          end
        end
      RUBY

      err = assert_raises(InstantRecord::Compiler::BuildError) do
        InstantRecord::Compiler::AppStage.analyze(source: app_root)
      end
      assert_match(/Missing controller for local_first route GET \/ghost -> ghosts#index/, err.message)

      # 4. Invalid explicit include override.
      File.write(File.join(app_root, "config/routes.rb"), <<~RUBY)
        Rails.application.routes.draw do
          local_first(include: { models: ["GhostModel"] }) do
            resources :tasks, only: [:index]
          end
        end
      RUBY

      err = assert_raises(InstantRecord::Compiler::BuildError) do
        InstantRecord::Compiler::AppStage.analyze(source: app_root)
      end
      assert_match(/Explicit include\.models entry "GhostModel" was not found/, err.message)
    end
  end

  test "EntryBuilder consumes manifest for synced models, sync_window, and sync_scope" do
    Dir.mktmpdir do |dir|
      emit = File.join(dir, "emit")
      FileUtils.mkdir_p(emit)
      File.write(File.join(emit, "main.rb"), <<~RUBY)
        require_relative "boot"
        if ARGV.length > 0 && ARGV[0] == "sidekiq"
          puts "sidekiq"
        end
      RUBY

      manifest = InstantRecord::Compiler::Manifest.new(
        "schema_version" => 1,
        "mode" => "island",
        "models" => [
          {
            "name" => "Comment",
            "table" => "comments",
            "file" => "app/models/comment.rb",
            "sync_window" => { "limit" => 25, "partition_by" => "task_id" },
            "sync_scope" => nil,
            "sync_file" => false
          },
          {
            "name" => "Task",
            "table" => "tasks",
            "file" => "app/models/task.rb",
            "sync_window" => nil,
            "sync_scope" => { "column" => "workspace_id", "policy" => false },
            "sync_file" => false
          }
        ],
        "local_routes" => [],
        "server_routes" => []
      )

      InstantRecord::Compiler::EntryBuilder.write_wasm_entry(
        emit_dir: emit,
        demo: false,
        manifest: manifest,
        migration_plan: { "version" => 1, "baseline" => nil, "migrations" => {} },
        pipeline_dir: PIPELINE_DIR
      )

      entry = File.read(File.join(emit, "main_wasm.rb"))
      assert_includes entry, "Comment.sync_window(limit: 25, partition_by: :task_id)"
      assert_includes entry, "Task.sync_scope(:workspace_id)"
      assert_includes entry, "InstantRecord.sync(Comment, Task)"
    end
  end

  test "real demo manifest discovers all demo server routes and local routes cleanly" do
    manifest = InstantRecord::Compiler.manifest(root: File.join(GEM_ROOT, "demo"))

    assert_equal "island", manifest.mode
    assert_equal %w[AssistantChat AssistantTurn AuthNote Channel ChatUser Issue MailEntry Message Note], manifest.synced_model_names

    server_pairs = manifest.server_routes.map { |r| [r["method"], r["path"]] }
    assert_includes server_pairs, ["POST", "/slack/reset"]
    assert_includes server_pairs, ["GET", "/auth/session"]
    assert_includes server_pairs, ["POST", "/auth/session"]
    assert_includes server_pairs, ["POST", "/auth/session/sign_out"]
    assert_includes server_pairs, ["POST", "/email/sync/:member/:inbox/incoming"]
    assert_includes server_pairs, ["GET", "/receipts/probe"]

    local_pairs = manifest.local_routes.map { |r| [r["method"], r["path"]] }
    assert_includes local_pairs, ["GET", "/"]
    assert_includes local_pairs, ["GET", "/todo"]
    assert_includes local_pairs, ["GET", "/slack"]
    assert_includes local_pairs, ["GET", "/slack/channels/:id"]
    assert_includes local_pairs, ["GET", "/email"]
    assert_includes local_pairs, ["POST", "/email"]
    assert_includes local_pairs, ["GET", "/assistant"]
    assert_includes local_pairs, ["GET", "/auth"]
    assert_includes local_pairs, ["GET", "/migrate"]
    assert_includes local_pairs, ["GET", "/console"]
    assert_includes local_pairs, ["GET", "/receipts"]
    assert_includes local_pairs, ["GET", "/receipts/probe"]
    refute_includes local_pairs, ["GET", "/source"]
    refute_includes local_pairs, ["POST", "/slack/reset"]
    refute_includes local_pairs, ["GET", "/auth/session"]
  end

  test "hardens edge cases: path traversal, status renders, abstract base models, brace blocks, and on: :collection" do
    Dir.mktmpdir do |dir|
      app_root = File.join(dir, "monolith")
      build_monolith_fixture(app_root)

      # Abstract base class between ApplicationRecord and Task, plus render with status: :unprocessable_entity
      File.write(File.join(app_root, "app/models/tenant_record.rb"), <<~RUBY)
        class TenantRecord < ApplicationRecord
          self.abstract_class = true
        end
      RUBY
      File.write(File.join(app_root, "app/models/task.rb"), <<~RUBY)
        class Task < TenantRecord
          include InstantRecord::Syncable
          include Taggable
          sync_scope :workspace_id
          has_many :comments
        end
      RUBY
      File.write(File.join(app_root, "app/views/tasks/new.html.erb"), "<form>new</form>\n")
      File.write(File.join(app_root, "app/controllers/tasks_controller.rb"), <<~RUBY)
        class TasksController < ApplicationController
          def index; @tasks = Task.all; end
          def create
            render :new, status: :unprocessable_entity
          end
        end
      RUBY
      File.write(File.join(app_root, "config/routes.rb"), <<~RUBY)
        Rails.application.routes.draw do
          namespace(:work) {
            local_first {
              resources :tasks, controller: "/tasks", only: [:index, :create] do
                get :recent, on: :collection
              end
            }
          }
        end
      RUBY

      result = InstantRecord::Compiler::AppStage.analyze(
        source: app_root,
        overrides: { include: { helpers: [:tasks_helper] }, server_routes: ["POST /export"] }
      )
      assert_includes result.trace.views, "app/views/tasks/new.html.erb"
      assert_includes result.trace.models, "app/models/tenant_record.rb"
      assert_includes result.manifest.staged["migrations"], "db/migrate/20261120000001_create_tasks.rb"
      assert_includes result.manifest.local_routes.map { |r| [r["method"], r["path"]] }, ["GET", "/work/tasks/recent"]
      assert_includes result.manifest.server_routes.map { |r| [r["method"], r["path"]] }, ["POST", "/export"]
      assert Prism.parse(result.route_analysis.local_routes_source).success?

      # Path traversal in include.files is rejected cleanly.
      secret = File.join(dir, "secret.txt")
      File.write(secret, "secret")
      err = assert_raises(InstantRecord::Compiler::BuildError) do
        InstantRecord::Compiler::AppStage.analyze(source: app_root, overrides: { include: { files: ["../secret.txt"] } })
      end
      assert_match(/does not exist inside/, err.message)

      # Path traversal in draw(:...) is rejected cleanly.
      File.write(File.join(app_root, "config/routes.rb"), "Rails.application.routes.draw { draw(:'../../secret') }\n")
      assert_raises(InstantRecord::Compiler::BuildError) do
        InstantRecord::Compiler::RouteAnalyzer.analyze(source_root: app_root)
      end
    end
  end

  private

  def assert_any_diagnostic(diagnostics, kind:, match:)
    found = diagnostics.find { |d| d["kind"] == kind && match.match?(d["message"]) }
    assert found, "Expected diagnostic kind=#{kind.inspect} matching #{match.inspect}, got: #{diagnostics.inspect}"
  end

  def build_monolith_fixture(root)
    %w[
      app/controllers/billing
      app/models/concerns
      app/views/layouts
      app/views/tasks
      app/views/shared
      app/views/billing/invoices
      app/helpers
      app/services
      app/jobs
      config/routes
      db/migrate
    ].each { |rel| FileUtils.mkdir_p(File.join(root, rel)) }

    File.write(File.join(root, "Gemfile"), "source 'https://rubygems.org'\n")
    File.write(File.join(root, "config/routes.rb"), <<~RUBY)
      Rails.application.routes.draw do
        get "up" => "rails/health#show"

        local_first do
          resources :tasks, only: [:index, :create]
        end

        draw(:billing)
      end
    RUBY
    File.write(File.join(root, "config/routes/billing.rb"), <<~RUBY)
      namespace :billing do
        resources :invoices, only: [:index]
        post "webhooks", to: "invoices#webhook"
      end
    RUBY

    File.write(File.join(root, "app/controllers/application_controller.rb"), "class ApplicationController < ActionController::Base\nend\n")
    File.write(File.join(root, "app/models/application_record.rb"), "class ApplicationRecord < ActiveRecord::Base\nend\n")
    File.write(File.join(root, "app/helpers/application_helper.rb"), "module ApplicationHelper\nend\n")
    File.write(File.join(root, "app/views/layouts/application.html.erb"), "<html><body><%= yield %></body></html>\n")

    # Local-first island: tasks + comments + taggable concern + shared partial + badge helper.
    File.write(File.join(root, "app/controllers/tasks_controller.rb"), <<~RUBY)
      class TasksController < ApplicationController
        extend InstantRecord::RuntimeScoped
        server_only do
          before_action { StripeClient.ping }
        end

        def index
          @tasks = Task.all
        end

        def create
          Task.create!(title: params[:title])
        end
      end
    RUBY
    File.write(File.join(root, "app/models/concerns/taggable.rb"), "module Taggable\nend\n")
    File.write(File.join(root, "app/models/task.rb"), <<~RUBY)
      class Task < ApplicationRecord
        include InstantRecord::Syncable
        include Taggable

        sync_scope :workspace_id
        has_many :comments

        server_only do
          after_create_commit { InvoicePdfJob.perform_later(id) }
        end
      end
    RUBY
    File.write(File.join(root, "app/models/comment.rb"), <<~RUBY)
      class Comment < ApplicationRecord
        include InstantRecord::Syncable
        sync_window limit: 25, partition_by: :task_id
        belongs_to :task
      end
    RUBY
    File.write(File.join(root, "app/helpers/tasks_helper.rb"), "module TasksHelper\n  def task_label(t) = t.title\nend\n")
    File.write(File.join(root, "app/helpers/badge_helper.rb"), "module BadgeHelper\n  def render_badge_text(s) = s.upcase\nend\n")
    File.write(File.join(root, "app/views/tasks/index.html.erb"), '<%= render "row" %>')
    File.write(File.join(root, "app/views/tasks/_row.html.erb"), '<%= render "shared/badge" %>')
    File.write(File.join(root, "app/views/shared/_badge.html.erb"), '<%= render_badge_text("ok") %>')

    # Unrelated monolith billing slice.
    File.write(File.join(root, "app/controllers/billing/invoices_controller.rb"), <<~RUBY)
      module Billing
        class InvoicesController < ApplicationController
          def index
            @invoices = Invoice.all
          end
        end
      end
    RUBY
    File.write(File.join(root, "app/models/invoice.rb"), "class Invoice < ApplicationRecord\n  belongs_to :stripe_customer\nend\n")
    File.write(File.join(root, "app/models/stripe_customer.rb"), "class StripeCustomer < ApplicationRecord\nend\n")
    File.write(File.join(root, "app/views/billing/invoices/index.html.erb"), "<h1>Billing</h1>\n")
    File.write(File.join(root, "app/helpers/billing_helper.rb"), "module BillingHelper\nend\n")
    File.write(File.join(root, "app/services/stripe_client.rb"), "class StripeClient\n  def self.ping = true\nend\n")
    File.write(File.join(root, "app/jobs/invoice_pdf_job.rb"), "class InvoicePdfJob\nend\n")

    # Migrations: tasks + comments are SQLite-portable; billing uses Postgres-only DDL that would fail BrowserMigrations!
    File.write(File.join(root, "db/schema.rb"), <<~RUBY)
      ActiveRecord::Schema[8.1].define(version: 2026_11_20_000003) do
      end
    RUBY
    File.write(File.join(root, "db/migrate/20261120000001_create_tasks.rb"), <<~RUBY)
      class CreateTasks < ActiveRecord::Migration[8.1]
        def change
          create_table :tasks, id: :string do |t|
            t.string :title
          end
        end
      end
    RUBY
    File.write(File.join(root, "db/migrate/20261120000002_create_comments.rb"), <<~RUBY)
      class CreateComments < ActiveRecord::Migration[8.1]
        def change
          create_table :comments, id: :string do |t|
            t.string :task_id
            t.text :body
          end
        end
      end
    RUBY
    File.write(File.join(root, "db/migrate/20261120000003_create_invoices_pg_only.rb"), <<~RUBY)
      class CreateInvoicesPgOnly < ActiveRecord::Migration[8.1]
        def change
          create_table :invoices do |t|
            t.string :stripe_id
          end
          add_foreign_key :invoices, :stripe_customers
        end
      end
    RUBY
  end
end
