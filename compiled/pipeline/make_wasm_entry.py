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
import shutil
import json
import re
if not os.environ.get("INSTANT_RECORD_APP"):
    shutil.copyfile(os.path.join(os.path.dirname(__file__), "sqlite_release.rb"),
                os.path.join(root, "app/models/release.rb"))
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

  # History has its own keyset and must not advance the live change cursor.
  # Keep the page receipt in the same SQLite transaction as its records.
  def self.history
    input = JSON.parse(File.read("/host/in"))
    key = "history:" + input["key"].to_s
    response = input["response"].to_s
    if response.empty?
      mark = InstantRecord::SyncMetadata.get(key)
      result = { ok: !mark.nil?, applied: 0, has_more: mark == "more" }
    else
      page = JSON.parse(response)
      records = Array(page["records"])
      more = page["has_more"] == true
      InstantRecord::OutboxMutation.transaction do
        records.each { |record| InstantRecord::Client.apply_change(record) }
        InstantRecord::SyncMetadata.set(key, more ? "more" : "end")
      end
      result = { ok: true, applied: records.size, has_more: more }
    end
    File.write("/host/out", JSON.generate(result))
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

# Earlier demos saved a cursor before Note was a synced model. Rehydrate once
# on a model-set change, preserving all local rows and pending mutations.
model_set = "COMPILED_MODEL_SET"
if InstantRecord::SyncMetadata.get("compiled_models") != model_set
  Schema.statements.each { |sql| SqliteAdapter.execute_ddl(sql) } if restored
  InstantRecord::SyncMetadata.where(key: "cursor").delete_all if restored
  InstantRecord::SyncMetadata.set("compiled_models", model_set)
end
Tep::APP.name = Rails.application.global_id_app
Message.sync_window(limit: 50, partition_by: :channel_id)
InstantRecord.sync(Issue, ChatUser, Channel, Message, Note)
# JS worker owns non-blocking inbound polling; Client#sync_pass handles bootstrap + outbox drain.
InstantRecord::Client.streaming = true
'''
models = ["Issue", "ChatUser", "Channel", "Message", "Note"]
if os.environ.get("INSTANT_RECORD_APP"):
    models = json.loads(os.environ["INSTANT_RECORD_MODELS"])
    if not models or not all(re.fullmatch(r"[A-Z]\w*(?:::[A-Z]\w*)*", name) for name in models):
        sys.exit("Declare at least one named model that includes InstantRecord::Syncable.")
    entry = entry.replace("Message.sync_window(limit: 50, partition_by: :channel_id)\n", "")
    entry = entry.replace("InstantRecord.sync(Issue, ChatUser, Channel, Message, Note)", "InstantRecord.sync(" + ", ".join(models) + ")")
entry = entry.replace("COMPILED_MODEL_SET", ",".join(sorted(models)))
open(os.path.join(root, "main_wasm.rb"), "w").write(head + entry)
print("wrote main_wasm.rb:", len(head.splitlines()), "lines of main.rb +", len(entry.splitlines()), "entry lines")
