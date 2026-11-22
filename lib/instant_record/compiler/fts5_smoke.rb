require "digest"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require_relative "native_build"
require_relative "runner"
require_relative "toolchain"
require_relative "wasm_build"

module InstantRecord
  class Compiler
    # Compiles and executes a minimal C program against the configured SQLite
    # amalgamation using the exact SQLITE_CFLAGS from NativeBuild and/or
    # WasmBuild to prove FTS5 virtual tables, BM25 ranking, prefix queries,
    # phrase queries, and snippets work offline in compiled SQLite.
    class Fts5Smoke
      TARGETS = %i[native wasm].freeze

      SMOKE_C = <<~'C'
        #include <stdio.h>
        #include <string.h>
        #include "sqlite3.h"

        static int fail(sqlite3 *db, const char *step, int rc) {
          fprintf(stderr, "fts5 smoke failed at %s (rc=%d): %s\n",
                  step, rc, db ? sqlite3_errmsg(db) : "no db");
          if (db) sqlite3_close(db);
          return 1;
        }

        int main(void) {
          sqlite3 *db = NULL;
          int rc = sqlite3_open(":memory:", &db);
          if (rc != SQLITE_OK) return fail(db, "open", rc);

          const char *setup =
            "CREATE VIRTUAL TABLE notes_fts USING fts5(title, body, tokenize='unicode61');"
            "INSERT INTO notes_fts(title, body) VALUES"
            "  ('Offline Sync', 'Local SQLite full text search works without network connectivity'),"
            "  ('File Chunks', 'Chunked uploads stay below reverse proxy request limits'),"
            "  ('Native iOS', 'Swift offline cache and full text search parity');";
          rc = sqlite3_exec(db, setup, NULL, NULL, NULL);
          if (rc != SQLITE_OK) return fail(db, "setup", rc);

          sqlite3_stmt *stmt = NULL;
          const char *rank_sql =
            "SELECT title, bm25(notes_fts), snippet(notes_fts, 1, '[', ']', '...', 8) "
            "FROM notes_fts WHERE notes_fts MATCH 'offline OR search' ORDER BY bm25(notes_fts);";
          rc = sqlite3_prepare_v2(db, rank_sql, -1, &stmt, NULL);
          if (rc != SQLITE_OK) return fail(db, "prepare rank", rc);

          int matches = 0;
          int snippet_marked = 0;
          while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
            const unsigned char *snippet = sqlite3_column_text(stmt, 2);
            if (snippet && strchr((const char *)snippet, '[') != NULL) snippet_marked = 1;
            matches++;
          }
          sqlite3_finalize(stmt);
          if (rc != SQLITE_DONE || matches != 2 || !snippet_marked) {
            fprintf(stderr, "fts5 rank check failed: rc=%d matches=%d snippet_marked=%d\n",
                    rc, matches, snippet_marked);
            sqlite3_close(db);
            return 1;
          }

          rc = sqlite3_prepare_v2(db, "SELECT count(*) FROM notes_fts WHERE notes_fts MATCH 'local*';", -1, &stmt, NULL);
          if (rc != SQLITE_OK) return fail(db, "prepare prefix", rc);
          int prefix_count = -1;
          if (sqlite3_step(stmt) == SQLITE_ROW) prefix_count = sqlite3_column_int(stmt, 0);
          sqlite3_finalize(stmt);
          if (prefix_count != 1) {
            fprintf(stderr, "fts5 prefix check failed: count=%d\n", prefix_count);
            sqlite3_close(db);
            return 1;
          }

          rc = sqlite3_prepare_v2(db, "SELECT title FROM notes_fts WHERE notes_fts MATCH '\"full text\" AND parity';", -1, &stmt, NULL);
          if (rc != SQLITE_OK) return fail(db, "prepare phrase", rc);
          char phrase[64] = {0};
          if (sqlite3_step(stmt) == SQLITE_ROW) {
            const unsigned char *text = sqlite3_column_text(stmt, 0);
            if (text) snprintf(phrase, sizeof(phrase), "%s", (const char *)text);
          }
          sqlite3_finalize(stmt);
          if (strcmp(phrase, "Native iOS") != 0) {
            fprintf(stderr, "fts5 phrase check failed: got '%s'\n", phrase);
            sqlite3_close(db);
            return 1;
          }

          sqlite3_close(db);
          printf("{\"ok\":true,\"matches\":%d,\"prefix\":%d,\"phrase\":\"%s\"}\n", matches, prefix_count, phrase);
          return 0;
        }
      C

      WASI_RUNNER_JS = <<~'JS'
        import { readFileSync } from "node:fs";
        import { WASI } from "node:wasi";

        const wasi = new WASI({ version: "preview1" });
        const wasm = await WebAssembly.compile(readFileSync(process.argv[2]));
        const instance = await WebAssembly.instantiate(wasm, wasi.getImportObject());
        wasi.start(instance);
      JS

      def self.run(toolchain:, target: :native)
        new(toolchain: toolchain, target: target).run
      end

      def initialize(toolchain:, target: :native)
        @toolchain = Toolchain.load(toolchain)
        @target = target.to_sym
        unless TARGETS.include?(@target)
          raise ArgumentError, "Unknown FTS5 smoke target: #{target.inspect} (expected :native or :wasm)"
        end
      end

      def run
        case @target
        when :native then run_native
        when :wasm then run_wasm
        end
      end

      private

      def run_native
        sqlite_src = @toolchain.fetch("SQLITE_SRC")
        cc = ENV.fetch("CC", "cc")
        Dir.mktmpdir("instant-record-fts5-native-") do |dir|
          runner = Runner.new(build_dir: dir)
          sqlite_obj = cached_sqlite_object(
            runner: runner,
            key_prefix: "fts5-native",
            cc: cc,
            cflags: NativeBuild::SQLITE_CFLAGS,
            sqlite_src: sqlite_src
          )
          smoke_c = File.join(dir, "smoke.c")
          binary = File.join(dir, "fts5_smoke")
          File.write(smoke_c, SMOKE_C)
          runner.run([cc, "-O2", "-I#{sqlite_src}", smoke_c, sqlite_obj, "-lm", "-o", binary])
          parse_result(runner.run([binary]))
        end
      end

      def run_wasm
        sqlite_src = @toolchain.fetch("SQLITE_SRC")
        clang = @toolchain.join("WASI_SDK", "bin/clang")
        node = Toolchain.which("node")
        raise BuildError, "node is required to execute the WASI FTS5 smoke binary" unless node

        Dir.mktmpdir("instant-record-fts5-wasm-") do |dir|
          runner = Runner.new(build_dir: dir)
          sqlite_obj = cached_sqlite_object(
            runner: runner,
            key_prefix: "fts5-wasm",
            cc: clang,
            cflags: WasmBuild::WASI_CFLAGS + WasmBuild::SQLITE_CFLAGS,
            sqlite_src: sqlite_src
          )
          smoke_c = File.join(dir, "smoke.c")
          wasm = File.join(dir, "fts5_smoke.wasm")
          js = File.join(dir, "run_wasi.mjs")
          File.write(smoke_c, SMOKE_C)
          File.write(js, WASI_RUNNER_JS)
          runner.run([
            clang, *WasmBuild::WASI_CFLAGS, WasmBuild::WASM_OPT_LEVEL,
            "-I#{sqlite_src}", smoke_c, sqlite_obj,
            "-lm",
            "-lwasi-emulated-signal", "-lwasi-emulated-process-clocks",
            "-lwasi-emulated-getpid", "-lwasi-emulated-mman",
            "-o", wasm
          ])
          parse_result(runner.run([node, "--no-warnings", js, wasm]))
        end
      end

      def cached_sqlite_object(runner:, key_prefix:, cc:, cflags:, sqlite_src:)
        sqlite_c = File.join(sqlite_src, "sqlite3.c")
        cache = @toolchain["CACHE"]
        digest = Digest::SHA256.hexdigest([cc, *cflags, sqlite_c, File.size(sqlite_c)].join("\0"))[0, 16]
        out_dir = cache && !cache.empty? ? File.join(cache, "#{key_prefix}-#{digest}") : runner.build_dir
        FileUtils.mkdir_p(out_dir)
        obj = File.join(out_dir, "sqlite3.o")
        unless File.exist?(obj)
          tmp_obj = File.join(out_dir, "sqlite3.#{Process.pid}.o")
          runner.run([cc, *cflags, "-c", sqlite_c, "-o", tmp_obj])
          File.rename(tmp_obj, obj)
        end
        obj
      end

      def parse_result(stdout)
        parsed = JSON.parse(stdout.strip)
        raise BuildError, "FTS5 smoke test returned #{parsed.inspect}" unless parsed["ok"] == true

        parsed.transform_keys(&:to_sym).merge(target: @target)
      end
    end
  end
end
