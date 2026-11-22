require "test_helper"
require "instant_record/compiler"

class Fts5Test < ActiveSupport::TestCase
  test "WasmBuild and NativeBuild both enable SQLite FTS5" do
    assert_includes InstantRecord::Compiler::WasmBuild::SQLITE_CFLAGS, "-DSQLITE_ENABLE_FTS5"
    assert_includes InstantRecord::Compiler::NativeBuild::SQLITE_CFLAGS, "-DSQLITE_ENABLE_FTS5"
  end

  test "Fts5Smoke validates target arguments" do
    Dir.mktmpdir do |dir|
      toolchain_file = File.join(dir, "toolchain.env")
      File.write(toolchain_file, "SQLITE_SRC=#{dir}\n")
      assert_raises(ArgumentError) do
        InstantRecord::Compiler::Fts5Smoke.run(toolchain: toolchain_file, target: :bogus)
      end
    end
  end

  test "ActiveRecord SQLite connection supports offline FTS5 virtual tables and bm25 ranking" do
    conn = ActiveRecord::Base.connection
    conn.execute("DROP TABLE IF EXISTS fts5_smoke_notes")
    conn.execute("CREATE VIRTUAL TABLE fts5_smoke_notes USING fts5(title, body, tokenize='unicode61')")
    conn.execute(<<~SQL)
      INSERT INTO fts5_smoke_notes(title, body) VALUES
        ('Offline Sync', 'Local SQLite full text search works without a network'),
        ('File Chunks', 'Proxy safe chunk sizes stay under reverse proxy ceilings'),
        ('Native iOS', 'Swift offline file store and full text search parity')
    SQL

    rows = conn.select_rows(<<~SQL)
      SELECT title, bm25(fts5_smoke_notes), snippet(fts5_smoke_notes, 1, '[', ']', '...', 8)
      FROM fts5_smoke_notes
      WHERE fts5_smoke_notes MATCH 'offline OR search'
      ORDER BY bm25(fts5_smoke_notes)
    SQL

    assert_equal 2, rows.size
    assert_equal %w[Native\ iOS Offline\ Sync], rows.map(&:first).sort
    assert rows.all? { |row| row[1].is_a?(Numeric) && row[1] <= 0 }
    assert rows.any? { |row| row[2].include?("[") }

    prefix_count = conn.select_value("SELECT count(*) FROM fts5_smoke_notes WHERE fts5_smoke_notes MATCH 'local*'")
    assert_equal 1, prefix_count
  ensure
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS fts5_smoke_notes")
  end

  test "compiled native SQLite supports FTS5 with NativeBuild::SQLITE_CFLAGS" do
    toolchain = available_toolchain
    skip "No SQLITE_SRC toolchain configured for compiled native FTS5 smoke test." unless toolchain

    result = InstantRecord::Compiler.verify_fts5(toolchain: toolchain, target: :native)
    assert_equal true, result[:ok]
    assert_equal :native, result[:target]
    assert_equal 2, result[:matches]
    assert_equal 1, result[:prefix]
    assert_equal "Native iOS", result[:phrase]
  end

  test "compiled WASI SQLite supports FTS5 with WasmBuild::SQLITE_CFLAGS" do
    toolchain = available_toolchain(require_wasi: true)
    skip "No WASI_SDK + SQLITE_SRC toolchain configured for compiled WASM FTS5 smoke test." unless toolchain

    result = InstantRecord::Compiler.verify_fts5(toolchain: toolchain, target: :wasm)
    assert_equal true, result[:ok]
    assert_equal :wasm, result[:target]
    assert_equal 2, result[:matches]
    assert_equal 1, result[:prefix]
    assert_equal "Native iOS", result[:phrase]
  end

  private

  def available_toolchain(require_wasi: false)
    candidates = [
      ENV["INSTANT_RECORD_TOOLCHAIN"],
      InstantRecord::Compiler.gem_root.join("compiled/toolchain.env").to_s,
      File.expand_path("~/.cache/instant-record-tools/toolchain.env")
    ].compact.uniq

    candidates.each do |path|
      next unless File.file?(path)

      tc = InstantRecord::Compiler::Toolchain.load(path)
      sqlite_c = tc["SQLITE_SRC"] && File.join(tc["SQLITE_SRC"], "sqlite3.c")
      next unless sqlite_c && File.file?(sqlite_c)

      if require_wasi
        clang = tc["WASI_SDK"] && File.join(tc["WASI_SDK"], "bin/clang")
        next unless clang && File.executable?(clang) && InstantRecord::Compiler::Toolchain.which("node")
      end
      return path
    end
    nil
  end
end
