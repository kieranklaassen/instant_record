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
        InstantRecord::Compiler.publish(root)
        response = app.get("https://browser.test/items", "HTTP_ACCEPT" => "text/html")
        assert_equal name, response.body
        assert_equal "no-cache", response["cache-control"]
      end
      assert_equal "module-a", app.get("https://browser.test/app-a.wasm").body
      assert_equal "Rails", app.get("https://server.test/items", "HTTP_ACCEPT" => "text/html").body
      assert_equal "Rails", app.get("https://browser.test/instant_record/bootstrap", "HTTP_ACCEPT" => "text/html").body
      assert_equal "Rails", app.post("https://browser.test/items").body
      assert_equal 404, app.get("https://browser.test/harness/missing.js").status
    end
  end
end
