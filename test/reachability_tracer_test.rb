require "test_helper"
require "instant_record/compiler"
require "fileutils"
require "tmpdir"

# What one `render` call tells the tracer: the templates and partials to stage,
# the layouts to stage, and the warning when the name is only known at runtime.
class ReachabilityTracerTest < ActiveSupport::TestCase
  PARTIAL_WARNING = "Dynamic partial render; declare targets in include: { partials: [...] }."
  TEMPLATE_WARNING = "Dynamic template render; declare targets in include: { views: [...] }."
  EXPRESSION_WARNING = "Dynamic render expression; declare targets in include: { partials: [...] } or include: { views: [...] }."

  test "a first argument names a template in a controller and a partial in a view or helper" do
    ['render "row"', "render :row", 'render "row", status: :created'].each do |code|
      assert_render code, renders: [[:template, "row"]]
      assert_render code, in: :view, renders: [[:partial, "row"]]
      assert_render code, in: :helper, renders: [[:partial, "row"]]
    end
    assert_render 'render "größe/行"', renders: [[:template, "größe/行"]]
  end

  test "partial wins over template, template over action, and action over the first argument" do
    assert_render 'render "d", action: "c", template: "b", partial: "a"', renders: [[:partial, "a"]]
    assert_render 'render "d", action: :c, template: :b', in: :view, renders: [[:template, "b"]]
    assert_render 'render "d", action: :c', in: :view, renders: [[:template, "c"]]
    assert_render 'render({ "partial" => :a })', renders: [[:partial, "a"]]
  end

  test "a name known only at runtime warns, except for action, and falls through to nothing else" do
    assert_render 'render "d", partial: pick, template: "b"', warnings: [PARTIAL_WARNING]
    assert_render 'render "d", template: 3, action: "c"', warnings: [TEMPLATE_WARNING]
    assert_render 'render "d", action: pick'
    assert_render 'render "d", partial: nil', warnings: [PARTIAL_WARNING]
    ["render @row", "render row, status: :ok", "render 3", "render nil", 'render "a#{b}"', "render(*rows)"].each do |code|
      assert_render code, warnings: [EXPRESSION_WARNING]
      assert_render code, in: :view, warnings: [EXPRESSION_WARNING]
    end
  end

  test "a render of something other than a template adds nothing, not even its layout" do
    %w[json plain html inline body xml js file head nothing].each do |key|
      assert_render "render partial: pick, #{key}: value, layout: \"card\""
    end
    ["render", "render { 1 }", "render(&block)", "render status: :ok", "render(**options)"].each { |code| assert_render code }
  end

  test "a layout follows the target, as a partial from a view, a helper or beside partial, else as a layout" do
    assert_render 'render "row", layout: :card', renders: [[:template, "row"]], layouts: ["card"]
    assert_render 'render "row", layout: "card"', in: :view, renders: [[:partial, "row"], [:partial, "card"]]
    assert_render 'render layout: "card"', in: :helper, renders: [[:partial, "card"]]
    assert_render 'render partial: "row", layout: "card"', renders: [[:partial, "row"], [:partial, "card"]]
    assert_render 'render partial: pick, layout: "card"', renders: [[:partial, "card"]], warnings: [PARTIAL_WARNING]
    assert_render 'render row, layout: "card"', layouts: ["card"], warnings: [EXPRESSION_WARNING]
    ["false", "nil", "pick"].each { |value| assert_render "render layout: #{value}" }
  end

  test "a render call spread over several lines is recorded at its first line" do
    assert_render "render(\n  \"row\",\n  layout: \"card\"\n)", renders: [[:template, "row"]], layouts: ["card"]
    assert_render "render(\n  partial: pick\n)", warnings: [PARTIAL_WARNING]
    assert_render "render(\n  template: pick\n)", warnings: [TEMPLATE_WARNING]
    assert_render "render(\n  row\n)", warnings: [EXPRESSION_WARNING]
  end

  test "a name that is not valid text is taken as it is, and an option key that is not raises" do
    assert_render 'render "\xff", layout: "\xfe"', renders: [[:template, "\xff"]], layouts: ["\xfe"]
    assert_equal '"\u0000"', visit('render :"\0"').renders.first[:target].inspect
    assert_raises(EncodingError) { visit('render "row", "\xff" => 1') }
    assert_raises(EncodingError) { visit('render json: 1, "\xff" => 1') }
  end

  test "a rendered name finds the views whose path continues it with a dot, in path order" do
    with_views("a/row", "a/row.html.erb", "a/row.json", "a/row.d/deep.erb", "a/row2.erb", "a/rows/row.erb", "b/row.erb") do
      assert_equal %w[a/row a/row.d/deep.erb a/row.html.erb a/row.json], rendered_views("row")
      assert_equal %w[a/row.html.erb], rendered_views("row.html")
      assert_equal %w[b/row.erb], rendered_views("b/row")
      assert_match "Missing template \"ro\"", assert_raises(InstantRecord::Compiler::BuildError) { rendered_views("ro") }.message
    end
  end

  test "a rendered name in an encoding that view names cannot be compared with raises" do
    with_views("a/é.erb", "a/row.erb") do
      assert_equal %w[a/row.erb], rendered_views("row", encoding: "ISO-8859-1")
      assert_raises(Encoding::CompatibilityError) { rendered_views("\xE9", encoding: "ISO-8859-1") }
    end
  end

  test "an escaped name in a US-ASCII source finds its view" do
    with_views("a/é.erb") do
      assert_equal %w[a/é.erb], rendered_views('\u00e9', encoding: "US-ASCII")
      assert_match "Missing template", assert_raises(InstantRecord::Compiler::BuildError) { rendered_views('\u00e8', encoding: "US-ASCII") }.message
    end
  end

  test "an include list stages what its entries name and reports each one that names nothing" do
    with_views("a/show.html.erb", "a/_row.html.erb", "a/_row.json") do
      %w[models/extra models/concerns/tagged controllers/b_controller helpers/money_helper jobs/mail_job].each do |file|
        write_app("app/#{file}.rb", "")
      end
      result = trace(
        models: %w[Extra Tagged], controllers: %w[B], helpers: %w[money], views: %w[a/show], partials: %w[a/row],
        files: %w[app/jobs/mail_job.rb]
      )
      assert_equal %w[app/models/concerns/tagged.rb app/models/extra.rb], result.models
      assert_equal %w[app/controllers/a_controller.rb app/controllers/b_controller.rb], result.controllers
      assert_equal %w[app/helpers/money_helper.rb], result.helpers
      assert_equal %w[app/views/a/_row.html.erb app/views/a/_row.json app/views/a/show.html.erb], result.views
      assert_equal %w[app/jobs/mail_job.rb], result.extra_files

      kinds = { models: "models", controllers: "controllers", helpers: "helpers", views: "views", partials: "views" }
      missing = kinds.map { |kind, dir| "  - Explicit include.#{kind} entry \"nope\" was not found under app/#{dir}/." }
      missing << "  - Explicit include.files entry \"nope\" does not exist inside #{@app}."
      error = assert_raises(InstantRecord::Compiler::BuildError) { trace(**kinds.transform_values { "nope" }, files: "nope") }
      assert_equal missing, error.message.lines(chomp: true).drop(1)
    end
  end

  test "the first file to take a constant's name keeps it" do
    with_views do
      {
        "models/apple" => %w[models/apple models/concerns/apple], # models in path order, concerns among them
        "models/concerns/zebra" => %w[models/concerns/zebra models/zebra],
        "helpers/money" => %w[controllers/concerns/money helpers/money]
      }.each do |first, files|
        files.each { |file| write_app("app/#{file}.rb", "") }
        write_app("app/controllers/application_controller.rb", File.basename(first).capitalize)
        result = trace
        assert_equal ["app/#{first}.rb"], (result.models + result.helpers), first
      end
    end
  end

  test "migration filtering handles escaped names, rename_table, execute SQL, word boundaries, and non-UTF-8 pragmas" do
    with_views("tasks/index.html.erb") do
      write_app("config/routes.rb", "Rails.application.routes.draw { local_first { resources :tasks, only: [:index] } }")
      write_app("app/controllers/tasks_controller.rb", "class TasksController\n  def index = Task.all\nend\n")
      write_app("app/models/application_record.rb", "class ApplicationRecord < ActiveRecord::Base; self.abstract_class = true; end\n")
      write_app("app/models/task.rb", "class Task < ApplicationRecord\n  include InstantRecord::Syncable\nend\n")
      write_app("db/migrate/20260101000001_escaped.rb", "class Escaped < ActiveRecord::Migration[8.1]\n  def change\n    create_table :\"ta\\x73ks\" do |t|\n      t.string :title\n    end\n  end\nend\n")
      write_app("db/migrate/20260101000002_rename_into.rb", "class RenameInto < ActiveRecord::Migration[8.1]\n  def change\n    rename_table :legacy_items, :tasks\n  end\nend\n")
      write_app("db/migrate/20260101000003_exec_sql.rb", "class ExecSql < ActiveRecord::Migration[8.1]\n  def change\n    execute \"UPDATE tasks SET title = 'ok'\"\n  end\nend\n")
      write_app("db/migrate/20260101000004_prefix_collision.rb", "class PrefixCollision < ActiveRecord::Migration[8.1]\n  def change\n    create_table :tasks_archive do |t|\n      t.string :title\n    end\n  end\nend\n")
      write_app("db/migrate/20260101000005_latin.rb", "# encoding: ISO-8859-1\n# caf\xE9\nclass Latin < ActiveRecord::Migration[8.1]\n  def change\n    add_column :tasks, :note, :string\n  end\nend\n")

      routes = InstantRecord::Compiler::RouteAnalyzer.analyze(source_root: @app)
      result = InstantRecord::Compiler::ReachabilityTracer.trace(source_root: @app, route_analysis: routes)

      assert_equal [
        "db/migrate/20260101000001_escaped.rb",
        "db/migrate/20260101000002_rename_into.rb",
        "db/migrate/20260101000003_exec_sql.rb",
        "db/migrate/20260101000005_latin.rb"
      ], result.manifest_migrations
    end
  end

  test "STI subclass checks respect word boundaries, non-UTF-8 encodings, spaced constants, and server_only blocks" do
    with_views("item1s/index.html.erb") do
      write_app("config/routes.rb", "Rails.application.routes.draw { local_first { resources :item1s, only: [:index] } }")
      write_app("app/controllers/item1s_controller.rb", "class Item1sController\n  def index = Item1.all\nend\n")
      write_app("app/models/application_record.rb", "class ApplicationRecord < ActiveRecord::Base; self.abstract_class = true; end\n")
      write_app("app/models/item1.rb", "class Item1 < ApplicationRecord\n  include InstantRecord::Syncable\nend\n")
      write_app("app/models/item12.rb", "class Item12 < ApplicationRecord\nend\n")
      write_app("app/models/latin_sub.rb", "# encoding: ISO-8859-1\n# caf\xE9\nclass LatinSub < Item1\nend\n")
      write_app("app/models/spaced_sub.rb", "class SpacedSub < ::Item1\nend\n")
      write_app("app/models/hidden_sub.rb", "server_only do\n  class HiddenSub < Item1\n  end\nend\n")

      routes = InstantRecord::Compiler::RouteAnalyzer.analyze(source_root: @app)
      result = InstantRecord::Compiler::ReachabilityTracer.trace(source_root: @app, route_analysis: routes)

      sti = result.diagnostics.select { |d| d["kind"] == "sti_subclass" }
      assert_equal 1, sti.size
      assert_match(/LatinSub, SpacedSub/, sti.first["message"])
      refute_match(/Item12|HiddenSub/, sti.first["message"])
    end
  end

  test "helper discovery handles tricky def forms, visibility, encoding pragmas, and preserves sorted helper order" do
    with_views do
      write_app("config/routes.rb", "Rails.application.routes.draw { local_first { resources :tasks, only: [:index] } }")
      write_app("app/controllers/tasks_controller.rb", "class TasksController; def index; end; end\n")
      write_app("app/helpers/a_helper.rb", "module AHelper\n  def # comment\n    commented_fn\n    1\n  end\nend\n")
      write_app("app/helpers/a2_helper.rb", "module A2Helper\n  def \\\n    continued_fn\n    2\n  end\nend\n")
      write_app("app/helpers/b_helper.rb", "# encoding: ISO-8859-1\n# caf\xE9\nmodule BHelper\n  def latin_fn; 'ok'; end\nend\n")
      write_app("app/helpers/c_helper.rb", "=begin\ndoc\n=end\nmodule CHelper\n  def shared_fn = 4\n  private\n  def private_fn = 5\nend\n")
      write_app("app/helpers/d_helper.rb", "module DHelper\n  server_only do\n    def server_fn = 6\n  end\n  def unused_fn = 7\nend\n")
      write_app("app/views/tasks/index.html.erb", "<%= commented_fn %><%= continued_fn %><%= latin_fn %><%= shared_fn %><%= private_fn %><%= server_fn %>\n")

      routes = InstantRecord::Compiler::RouteAnalyzer.analyze(source_root: @app)
      result = InstantRecord::Compiler::ReachabilityTracer.trace(source_root: @app, route_analysis: routes)

      assert_equal %w[app/helpers/a2_helper.rb app/helpers/a_helper.rb app/helpers/b_helper.rb app/helpers/c_helper.rb], result.helpers
    end
  end

  test "ERB tracing preserves line numbers, multibyte offsets, underscore helper calls, and syntax error boundaries" do
    with_views do
      write_app("config/routes.rb", "Rails.application.routes.draw { local_first { resources :tasks, only: [:index, :show] } }")
      write_app("app/controllers/tasks_controller.rb", "class TasksController; def index; end; def show; end; end\n")
      write_app("app/helpers/under_helper.rb", "module UnderHelper\n  def _; 'u'; end\nend\n")
      write_app("app/helpers/ready_helper.rb", "module ReadyHelper\n  def ready?(x) = true\nend\n")
      write_app("app/views/tasks/_row.html.erb", "<div>plain static html</div>\n")
      write_app("app/views/tasks/show.html.erb", "<div>no erb tags at all</div>\n")
      write_app("app/views/tasks/index.html.erb", <<~ERB)
        <p>日本語 — café</p>
        <%# multiline
            comment %>
        <%%= literal_erb %>
        <%- x = 1 -%>
        <%= _ %>
        <%= ready?(x) -%>
        <%== render "row" %>
        <%= content_tag(:div) do %>
          <%= render @card %>
        <% end %>
      ERB

      routes = InstantRecord::Compiler::RouteAnalyzer.analyze(source_root: @app)
      result = InstantRecord::Compiler::ReachabilityTracer.trace(source_root: @app, route_analysis: routes)

      assert_equal %w[app/helpers/ready_helper.rb app/helpers/under_helper.rb], result.helpers
      assert_equal %w[app/views/tasks/_row.html.erb app/views/tasks/index.html.erb app/views/tasks/show.html.erb], result.views
      render_warn = result.diagnostics.find { |d| d["kind"] == "render" }
      assert_equal 9, render_warn["line"]

      # Comment followed by multiline HTML text must still raise an ERB syntax error.
      write_app("app/views/tasks/show.html.erb", "<% # oops %>hello\nworld\n")
      err = assert_raises(InstantRecord::Compiler::BuildError) do
        InstantRecord::Compiler::ReachabilityTracer.trace(source_root: @app, route_analysis: routes)
      end
      assert_match(/ERB syntax error in app\/views\/tasks\/show\.html\.erb/, err.message)

      # Static HTML between case and when must still raise an ERB syntax error.
      write_app("app/views/tasks/show.html.erb", "<% case x %>text<% when 1 %>ok<% end %>")
      err = assert_raises(InstantRecord::Compiler::BuildError) do
        InstantRecord::Compiler::ReachabilityTracer.trace(source_root: @app, route_analysis: routes)
      end
      assert_match(/ERB syntax error in app\/views\/tasks\/show\.html\.erb/, err.message)
    end
  end

  test "full-app tracing still reports syntax errors, dynamic warnings, and concern syncable propagation" do
    with_views do
      write_app("config/routes.rb", "Rails.application.routes.draw { resources :tasks, only: [:index] }")
      write_app("app/models/application_record.rb", "class ApplicationRecord < ActiveRecord::Base; self.abstract_class = true; end\n")
      write_app("app/models/concerns/sync_mix.rb", "module SyncMix\n  include InstantRecord::Syncable\nend\n")
      write_app("app/models/task.rb", "class Task < ApplicationRecord\n  include SyncMix\nend\n")
      write_app("app/controllers/tasks_controller.rb", "class TasksController\n  def index\n    'Foo'.safe_constantize\n  end\nend\n")
      write_app("app/views/tasks/index.html.erb", "<%= render @dyn %>\n")

      routes = InstantRecord::Compiler::RouteAnalyzer.analyze(source_root: @app)
      result = InstantRecord::Compiler::ReachabilityTracer.trace(source_root: @app, route_analysis: routes)

      assert_equal true, result.model_metadata.dig("Task", "syncable")
      assert_equal %w[safe_constantize render], result.diagnostics.map { |d| d["kind"] }

      write_app("app/controllers/tasks_controller.rb", "class TasksController\n  def index\n    if true\nend\n")
      err = assert_raises(InstantRecord::Compiler::BuildError) do
        InstantRecord::Compiler::ReachabilityTracer.trace(source_root: @app, route_analysis: routes)
      end
      assert_match(/Syntax error in app\/controllers\/tasks_controller\.rb/, err.message)

      write_app("app/controllers/tasks_controller.rb", "class TasksController; def index; end; end\n")
      write_app("app/views/tasks/index.html.erb", "<div>\n  <%= 1 + %>\n</div>\n")
      err = assert_raises(InstantRecord::Compiler::BuildError) do
        InstantRecord::Compiler::ReachabilityTracer.trace(source_root: @app, route_analysis: routes)
      end
      assert_match(/ERB syntax error in app\/views\/tasks\/index\.html\.erb: line 2:/, err.message)
    end
  end

  test "visitor traverses constants in parameter defaults, constant writes, and logical/control nodes" do
    with_views do
      write_app("config/routes.rb", "Rails.application.routes.draw { local_first { resources :tasks, only: [:index] } }")
      write_app("app/controllers/tasks_controller.rb", <<~RUBY)
        class TasksController
          DEFAULT_MODEL = ModelA
          def index(a = ModelB.first, b: ModelC.first)
            return ModelD.first unless ModelE.first
            ModelF.first || ModelG.first && ModelH.first
          end
        end
      RUBY
      %w[a b c d e f g h].each { |ch| write_app("app/models/model_#{ch}.rb", "class Model#{ch.upcase}; end\n") }

      routes = InstantRecord::Compiler::RouteAnalyzer.analyze(source_root: @app)
      result = InstantRecord::Compiler::ReachabilityTracer.trace(source_root: @app, route_analysis: routes)

      assert_equal %w[a b c d e f g h].map { |ch| "app/models/model_#{ch}.rb" }, result.models
    end
  end

  test "constant naming respects custom ActiveSupport::Inflector acronyms" do
    with_views do
      inflections = ActiveSupport::Inflector.inflections(:en)
      saved_acronyms = inflections.acronyms.values.dup
      inflections.acronym("API")
      begin
        write_app("config/routes.rb", "Rails.application.routes.draw { local_first { resources :api_items, only: [:index] } }")
        write_app("app/controllers/api_items_controller.rb", "class APIItemsController\n  def index = APIItem.all\nend\n")
        write_app("app/models/api_item.rb", "class APIItem; end\n")

        routes = InstantRecord::Compiler::RouteAnalyzer.analyze(source_root: @app)
        result = InstantRecord::Compiler::ReachabilityTracer.trace(source_root: @app, route_analysis: routes)

        assert_equal %w[app/models/api_item.rb], result.models
      ensure
        inflections.clear(:acronyms)
        saved_acronyms.each { |acronym| inflections.acronym(acronym) }
      end
    end
  end

  test "ERB fallback handles heredocs spanning static text and preserves trimmed code-tag rspace errors" do
    with_views do
      write_app("config/routes.rb", "Rails.application.routes.draw { local_first { resources :tasks, only: [:index] } }")
      write_app("app/controllers/tasks_controller.rb", "class TasksController; def index; end; end\n")
      write_app("app/views/tasks/index.html.erb", "<%= content_tag(:div, <<~TXT) do %>\nhello\nTXT\n<% end %>\n")

      routes = InstantRecord::Compiler::RouteAnalyzer.analyze(source_root: @app)
      result = InstantRecord::Compiler::ReachabilityTracer.trace(source_root: @app, route_analysis: routes)
      assert_equal ["app/views/tasks/index.html.erb"], result.views

      # Trimmed code tag with trailing spaces after %> breaks heredoc terminator in Erubi
      write_app("app/views/tasks/index.html.erb", "<% x = <<~SQL\n  SELECT 1\nSQL%>   \n<%= render @a %>\n")
      err = assert_raises(InstantRecord::Compiler::BuildError) do
        InstantRecord::Compiler::ReachabilityTracer.trace(source_root: @app, route_analysis: routes)
      end
      assert_match(/ERB syntax error in app\/views\/tasks\/index\.html\.erb/, err.message)

      # Indented trimmed code tag preserves lspace so non-squiggly heredoc terminator fails like Erubi
      write_app("app/views/tasks/index.html.erb", "<% x = <<EOF\n  hi\n%>\n  <%EOF%>\n<%= render @a %>\n")
      err = assert_raises(InstantRecord::Compiler::BuildError) do
        InstantRecord::Compiler::ReachabilityTracer.trace(source_root: @app, route_analysis: routes)
      end
      assert_match(/ERB syntax error in app\/views\/tasks\/index\.html\.erb/, err.message)
    end
  end

  test "full-app mode matches dynamic constant path/module warnings and skips dynamic class superclasses" do
    with_views do
      write_app("config/routes.rb", "Rails.application.routes.draw { resources :tasks, only: [:index] }")
      write_app("app/controllers/tasks_controller.rb", <<~RUBY)
        class TasksController < "ApplicationController".constantize
          def index
            a = "Foo".constantize::BAR
            b = Object.const_get(:Baz)::QUX
          end
        end
        module Object.const_get(:DynMod)::Sub
        end
      RUBY

      routes = InstantRecord::Compiler::RouteAnalyzer.analyze(source_root: @app)
      result = InstantRecord::Compiler::ReachabilityTracer.trace(source_root: @app, route_analysis: routes)
      assert_equal [[3, "constantize"], [4, "const_get"], [7, "const_get"]], result.diagnostics.map { |d| [d["line"], d["kind"]] }
    end
  end

  test "lazy helper indexing handles defs without whitespace before splats, blocks, forwarding, continuations, or predicate args" do
    with_views do
      write_app("config/routes.rb", "Rails.application.routes.draw { local_first { resources :tasks, only: [:index] } }")
      write_app("app/controllers/tasks_controller.rb", "class TasksController; def index; end; end\n")
      write_app("app/helpers/splat_helper.rb", "module SplatHelper\n  def fmt*args; args; end\nend\n")
      write_app("app/helpers/block_helper.rb", "module BlockHelper\n  def wrap&blk; blk; end\nend\n")
      write_app("app/helpers/pred_helper.rb", "module PredHelper\n  def ok?x; x; end\nend\n")
      write_app("app/helpers/fwd_helper.rb", "module FwdHelper\n  def fwd...; 1; end\nend\n")
      write_app("app/helpers/cont_helper.rb", "module ContHelper\n  def cont\\\n(x); x; end\nend\n")
      write_app("app/helpers/comment_def_helper.rb", "module CommentDefHelper\n  # describes def\n  def real_helper\n    \"ok\"\n  end\nend\n")
      write_app("app/views/tasks/index.html.erb", "<%= fmt(1) %><%= wrap { 2 } %><%= ok?(3) %><%= fwd(4) %><%= cont(5) %><%= real_helper %>\n")

      routes = InstantRecord::Compiler::RouteAnalyzer.analyze(source_root: @app)
      result = InstantRecord::Compiler::ReachabilityTracer.trace(source_root: @app, route_analysis: routes)
      assert_equal %w[
        app/helpers/block_helper.rb
        app/helpers/comment_def_helper.rb
        app/helpers/cont_helper.rb
        app/helpers/fwd_helper.rb
        app/helpers/pred_helper.rb
        app/helpers/splat_helper.rb
      ], result.helpers
    end
  end

  test "handles multibyte UTF-8 directory names in stageable models and unstaged app directories" do
    with_views do
      write_app("config/routes.rb", "Rails.application.routes.draw { local_first { resources :tasks, only: [:index] } }")
      write_app("app/controllers/tasks_controller.rb", "module Café\n  class ::TasksController\n    def index = Item.all\n  end\nend\n")
      write_app("app/models/café/item.rb", "module Café\n  class Item; end\nend\n")
      write_app("app/models/日本語/unused.rb", "module 日本語\n  class Unused; end\nend\n")

      routes = InstantRecord::Compiler::RouteAnalyzer.analyze(source_root: @app)
      result = InstantRecord::Compiler::ReachabilityTracer.trace(source_root: @app, route_analysis: routes)
      assert_equal ["app/models/café/item.rb"], result.models

      # Unstaged file under a multibyte UTF-8 top-level app directory still triggers missing-symbol error
      write_app("app/café/secret_job.rb", "class SecretJob; end\n")
      write_app("app/controllers/tasks_controller.rb", "class TasksController\n  def index = SecretJob.new\nend\n")
      err = assert_raises(InstantRecord::Compiler::BuildError) do
        InstantRecord::Compiler::ReachabilityTracer.trace(source_root: @app, route_analysis: routes)
      end
      assert_match(/SecretJob/, err.message)
      assert_match(/app\/café\/secret_job\.rb/, err.message)
    end
  end

  test "unstaged constant indexing does not traverse symlinked top-level app directories" do
    with_views do
      Dir.mktmpdir do |outside|
        File.write(File.join(outside, "external_job.rb"), "class ExternalJob; end\n")
        write_app("config/routes.rb", "Rails.application.routes.draw { local_first { resources :tasks, only: [:index] } }")
        write_app("app/controllers/tasks_controller.rb", "class TasksController; def index = ExternalJob.new; end\n")
        File.symlink(outside, File.join(@app, "app/jobs"))

        routes = InstantRecord::Compiler::RouteAnalyzer.analyze(source_root: @app)
        result = InstantRecord::Compiler::ReachabilityTracer.trace(source_root: @app, route_analysis: routes)
        assert_equal ["app/controllers/tasks_controller.rb"], result.controllers
      end
    end
  end

  test "migration filter handles underscore-delimited percent literals and form-feed magic encoding comments" do
    with_views do
      write_app("config/routes.rb", "Rails.application.routes.draw { local_first { resources :tasks, only: [:index] } }")
      write_app("app/controllers/tasks_controller.rb", "class TasksController; def index = Task.all; end\n")
      write_app("app/models/task.rb", "class Task < ApplicationRecord; include InstantRecord::Syncable; end\n")
      write_app("db/migrate/20260101000001_pct.rb", "class Pct < ActiveRecord::Migration[8.1]\n  def change\n    create_table %q_tasks_\n  end\nend\n")
      write_app("db/migrate/20260101000002_ff_enc.rb", "\f# encoding: ISO-8859-1\nclass FfEnc < ActiveRecord::Migration[8.1]\n  def change\n    add_column :tasks, :note, :string\n  end\nend\n")

      routes = InstantRecord::Compiler::RouteAnalyzer.analyze(source_root: @app)
      result = InstantRecord::Compiler::ReachabilityTracer.trace(source_root: @app, route_analysis: routes)
      assert_equal %w[db/migrate/20260101000001_pct.rb db/migrate/20260101000002_ff_enc.rb], result.manifest_migrations
    end
  end

  private

  def with_views(*views)
    Dir.mktmpdir do |dir|
      @app = dir
      views.each { |view| write_app("app/views/#{view}", "") }
      yield
    end
  end

  def write_app(rel, content)
    path = File.join(@app, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
  end

  def trace(**include)
    write_app("config/routes.rb", "Rails.application.routes.draw { local_first { post 'a', to: 'a#create' } }")
    write_app("app/controllers/a_controller.rb", "")
    routes = InstantRecord::Compiler::RouteAnalyzer.analyze(source_root: @app)
    InstantRecord::Compiler::ReachabilityTracer.trace(source_root: @app, route_analysis: routes, overrides: { include: include })
  end

  # The views staged when a controller without views of its own renders +name+.
  def rendered_views(name, encoding: "UTF-8")
    write_app("config/routes.rb", "Rails.application.routes.draw { local_first { post 'a', to: 'a#create' } }")
    write_app("app/controllers/a_controller.rb", "# encoding: #{encoding}\nclass AController\n  def create = render(\"#{name}\")\nend\n")
    routes = InstantRecord::Compiler::RouteAnalyzer.analyze(source_root: @app)
    result = InstantRecord::Compiler::ReachabilityTracer.trace(source_root: @app, route_analysis: routes)
    result.views.map { |view| view.delete_prefix("app/views/") }
  end

  def visit(code, place = :controller)
    visitor = InstantRecord::Compiler::ReachabilityTracer::FileVisitor.new(
      rel_path: "app/file.rb", is_view: place == :view, is_helper: place == :helper
    )
    parsed = Prism.parse("\n#{code}")
    assert parsed.success?, code
    parsed.value.accept(visitor)
    visitor
  end

  def assert_render(code, renders: [], layouts: [], warnings: [], **place)
    visitor = visit(code, place.fetch(:in, :controller))
    assert_equal renders.map { |kind, target| { kind: kind, target: target, line: 2 } }, visitor.renders, code
    assert_equal layouts.map { |target| { target: target, line: 2 } }, visitor.layouts, code
    expected = warnings.map do |message|
      { "level" => "warning", "kind" => "render", "file" => "app/file.rb", "line" => 2, "message" => message }
    end
    assert_equal expected, visitor.dynamic_warnings, code
  end
end
