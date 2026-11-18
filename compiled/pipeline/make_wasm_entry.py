#!/usr/bin/env python3
"""Write main_wasm.rb into an emitted Spinel project.

The emitted main.rb ends by starting a threaded TCP server, and WASI has neither threads nor
sockets. main_wasm.rb is main.rb up to that point (the Main module and its dispatch, unchanged)
followed by a persistent WASI reactor bridge: boot once (SQLite + runtime stay warm), then serve
HTTP requests and sync passes through /host/in and /host/out.
"""
import os
import sys

root = sys.argv[1]
source = open(os.path.join(root, "main.rb")).read()
marker = '\nif ARGV.length > 0 && ARGV[0] == "sidekiq"'
head = source[: source.index(marker)]

entry = r'''

# ── persistent reactor entry for wasm32-wasi (see make_wasm_entry.py) ─────────
#
# app_boot (top-level): configures SQLite and registers syncable models once.
# WasmBridge.handle_request: reads raw HTTP request from /host/in, writes status + headers + body
#   to /host/out.
# WasmBridge.handle_sync: reads sync endpoint from /host/in, runs InstantRecord::Client.sync_pass,
#   writes summary to /host/out.

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

  def self.handle_sync
    endpoint = File.read("/host/in").strip
    InstantRecord.config.endpoint = endpoint if endpoint.length > 0
    changed = InstantRecord::Client.sync_pass
    File.write("/host/out", (changed ? "changed" : "unchanged") + " pending=" + InstantRecord::Client.pending_count.to_s)
    0
  end
end

Main.configure_default_adapter!
Tep::APP.name = Rails.application.global_id_app
InstantRecord.sync(Issue, ChatUser, Channel, Message)
'''
open(os.path.join(root, "main_wasm.rb"), "w").write(head + entry)
print("wrote main_wasm.rb:", len(head.splitlines()), "lines of main.rb +", len(entry.splitlines()), "entry lines")
