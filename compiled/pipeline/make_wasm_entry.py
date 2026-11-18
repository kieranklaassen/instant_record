#!/usr/bin/env python3
"""Write main_wasm.rb into an emitted Spinel project.

The emitted main.rb ends by starting a threaded TCP server, and WASI has neither threads nor
sockets. main_wasm.rb is main.rb up to that point (the Main module and its dispatch, unchanged)
followed by a persistent WASI reactor bridge: boot once (SQLite + runtime stay warm), then serve
HTTP requests, outbox drains, and async-fetched change batches through /host/in and /host/out.
"""
import os
import sys

root = sys.argv[1]
source = open(os.path.join(root, "main.rb")).read()
marker = '\nif ARGV.length > 0 && ARGV[0] == "sidekiq"'
head = source[: source.index(marker)]

entry = r'''

# ── persistent reactor entry for wasm32-wasi (see make_wasm_entry.py) ─────────

class Hash
  def deep_stringify_keys
    result = {}
    each do |key, value|
      result[key.to_s] = value.is_a?(Hash) ? value.deep_stringify_keys : value
    end
    result
  end
end

module WasmBridge
  def self.handle_request
    req = Tep::Parser.parse(File.read("/host/in"))
    res = Tep::Response.new
    Tep::APP.dispatch(req, res)
    out = +""
    out << res.status.to_s << "\n"
    res.headers.each { |name, value| out << name.to_s << ": " << value.to_s << "\n" }
    res.header_fields.each { |pair| out << pair[0].to_s << ": " << pair[1].to_s << "\n" }
    res.set_cookies.each { |cookie| out << "Set-Cookie: " << cookie.to_s << "\n" }
    out << "X-File-Path: " << res.file_path << "\n" if res.file_path.length > 0
    out << "\n" << res.body
    File.write("/host/out", out)
    0
  end

  # Capture the exact outgoing batch before the worker yields to browser requests.
  def self.sync_plan
    mutations = InstantRecord::Client.pending_mutations
    push = mutations.empty? ? "" : JSON.generate({ mutations: mutations })
    File.write("/host/out", JSON.generate({ push: push, bootstrap: !InstantRecord::Client.bootstrapped? }))
    0
  end

  def self.handle_sync
    endpoint = File.read("/host/in").strip
    InstantRecord.config.endpoint = endpoint if endpoint.length > 0
    changed = InstantRecord::Client.sync_pass
    File.write("/host/out", (changed ? "changed" : "unchanged") + " pending=" + InstantRecord::Client.pending_count.to_s + " cursor=" + InstantRecord::Client.cursor.to_s)
    0
  end

  def self.handle_stream
    applied = InstantRecord::Client.consume_stream(File.read("/host/in"))
    File.write("/host/out", "applied=" + applied.to_s + " cursor=" + InstantRecord::Client.cursor.to_s)
    0
  end

  def self.cursor
    File.write("/host/out", "cursor=" + InstantRecord::Client.cursor.to_s + " pending=" + InstantRecord::Client.pending_count.to_s + " bootstrap=" + (InstantRecord::Client.bootstrapped? ? "ready" : "needed"))
    0
  end
end

db_path = Main.default_db_path
restored = File.exist?(db_path) && File.size(db_path) > 0
SqliteAdapter.configure(db_path)
ActiveRecord.adapter = SqliteAdapter
SqliteAdapter.execute_ddl("PRAGMA locking_mode = EXCLUSIVE")
SqliteAdapter.execute_ddl("PRAGMA journal_mode = MEMORY")
SqliteAdapter.execute_ddl("PRAGMA cache_size = -4000")
Schema.statements.each { |sql| SqliteAdapter.execute_ddl(sql) } unless restored

Tep::APP.name = Rails.application.global_id_app
InstantRecord.sync(Issue, ChatUser, Channel, Message)
# JS worker owns non-blocking inbound polling; Client#sync_pass handles bootstrap + outbox drain.
InstantRecord::Client.streaming = true
'''
open(os.path.join(root, "main_wasm.rb"), "w").write(head + entry)
print("wrote main_wasm.rb:", len(head.splitlines()), "lines of main.rb +", len(entry.splitlines()), "entry lines")
