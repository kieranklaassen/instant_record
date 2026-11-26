require_relative "test_helper"
require_relative "../compiled/pipeline/browser_migrations"
require_relative "../lib/instant_record/compiler"
require_relative "../lib/instant_record/compiled_site"
require "rack/mock"
require "tempfile"

class CompiledReleaseTest < Minitest::Test
  def compile(body)
    Tempfile.create(["migration", ".rb"]) do |file|
      file.write("class Upgrade < ActiveRecord::Migration[8.1]\n def change\n#{body}\nend\nend")
      file.flush
      BrowserMigrations.new(ActiveRecord::Base.connection).compile(file.path)
    end
  end

  def test_migration_backfills_existing_data_and_creates_rails_indexes
    db = ActiveRecord::Base.connection
    db.transaction do
      statements = compile(<<~RUBY)
        create_table :release_rows, id: :string do |t|
          t.string :title, null: false
          t.index :title, unique: true
        end
        execute "INSERT INTO release_rows (id, title) VALUES ('local', 'saved')"
        add_column :release_rows, :score, :integer, default: 0, null: false
        execute "UPDATE release_rows SET score = length(title)"
      RUBY
      statements.each { |sql| db.execute(sql) }
      assert_equal 5, db.select_value("SELECT score FROM release_rows WHERE id = 'local'")
      assert db.index_exists?(:release_rows, :title, unique: true)
      raise ActiveRecord::Rollback
    end
  end

  def test_dynamic_ruby_is_refused_without_running_it_on_the_build_machine
    assert_raises(RuntimeError) { compile("add_column :users, ENV.fetch('NAME'), :integer") }
    assert_raises(RuntimeError) { compile("SomeModel.find_each(&:destroy!)") }
  end

  def test_rails_serves_the_published_release_and_keeps_sync_on_the_server
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      dist = root.join("tmp/instant_record/compiled/web/dist")
      FileUtils.mkdir_p(dist)
      backend = ->(_env) { [200, {}, ["Rails"]] }
      app = Rack::MockRequest.new(InstantRecord::CompiledSite.new(backend, host: "browser.test",
        root: root.join("public/instant_record_compiled/current").to_s, sync_path: "/instant_record"))
      %w[a b].each do |name|
        FileUtils.rm_f(dist.join("app-a.wasm"))
        dist.join("app-#{name}.wasm").write("module-#{name}")
        dist.join("index.html").write(name)
        dist.join("instant-record-release.json").write(JSON.generate(version: name * 64))
        dist.join("instant_record.manifest.json").write(JSON.generate(schema_version: 1, mode: "full"))
        InstantRecord::Compiler.publish(root)
        response = app.get("https://browser.test/items", "HTTP_ACCEPT" => "text/html")
        assert_equal name, response.body
        assert_equal "no-cache", response["cache-control"]
      end
      assert_equal 200, app.get("https://browser.test/instant_record.manifest.json").status
      assert_equal "module-a", app.get("https://browser.test/app-a.wasm").body
      assert_equal "Rails", app.get("https://server.test/items", "HTTP_ACCEPT" => "text/html").body
      assert_equal "Rails", app.get("https://browser.test/instant_record/bootstrap", "HTTP_ACCEPT" => "text/html").body
      assert_equal "Rails", app.post("https://browser.test/items").body
      assert_equal 404, app.get("https://browser.test/harness/missing.js").status
      assert_equal "Rails", app.get("https://browser.test/service-worker.js").body

      dist.join("service-worker.js").write("// sw v2")
      dist.join("instant-record-release.json").write(JSON.generate(version: "c" * 64))
      InstantRecord::Compiler.publish(root)
      sw = app.get("https://browser.test/service-worker.js")
      assert_equal 200, sw.status
      assert_equal "// sw v2", sw.body
      assert_equal "no-cache", sw["cache-control"]

      # In island mode, non-island HTML routes pass through to Rails instead of serving index.html.
      island_manifest = {
        schema_version: 1,
        mode: "island",
        local_routes: [{ method: "GET", path: "/items" }, { method: "GET", path: "/items/:id" }]
      }
      dist.join("instant_record.manifest.json").write(JSON.generate(island_manifest))
      dist.join("instant-record-release.json").write(JSON.generate(version: "d" * 64))
      dist.join("app-d.wasm").write("module-d")
      InstantRecord::Compiler.publish(root)
      assert_equal "b", app.get("https://browser.test/items", "HTTP_ACCEPT" => "text/html").body
      assert_equal "b", app.get("https://browser.test/items/42", "HTTP_ACCEPT" => "text/html").body
      assert_equal "Rails", app.get("https://browser.test/billing/invoices", "HTTP_ACCEPT" => "text/html").body
    end
  end

  def test_precompressed_copies_are_served_to_browsers_that_accept_them
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      { "app-a.wasm" => "raw", "app-a.wasm.br" => "brotli", "app-a.wasm.gz" => "gzip", "index.html" => "page", "index.html.gz" => "zpage" }
        .each { |name, body| root.join(name).write(body) }
      app = Rack::MockRequest.new(InstantRecord::CompiledSite.new(->(_env) { [200, {}, ["Rails"]] },
        host: "browser.test", root: dir, sync_path: "/instant_record"))
      get = ->(accept, extra = {}) { app.get("https://browser.test/app-a.wasm", { "HTTP_ACCEPT_ENCODING" => accept }.merge(extra)) }

      best = get.call("gzip, deflate, br")
      assert_equal ["brotli", "br", "application/wasm", "accept-encoding"],
        [best.body, best["content-encoding"], best["content-type"], best["vary"]]
      assert_includes best["cache-control"], "immutable"
      assert_equal "gzip", get.call("gzip, br;q=0").body
      [get.call(nil), get.call("identity"), get.call("br", "HTTP_RANGE" => "bytes=0-1")].each do |plain|
        assert_nil plain["content-encoding"]
        assert_includes %w[raw ra], plain.body
      end
      page = app.get("https://browser.test/items", "HTTP_ACCEPT" => "text/html", "HTTP_ACCEPT_ENCODING" => "br, gzip")
      assert_equal ["zpage", "gzip", "text/html", "no-cache"],
        [page.body, page["content-encoding"], page["content-type"], page["cache-control"]]
    end
  end
end
