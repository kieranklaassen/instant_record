#!/usr/bin/env python3
"""Write main_wasm.rb into an emitted Spinel project.

The emitted main.rb ends by starting a threaded TCP server, and WASI has neither threads nor
sockets. main_wasm.rb is main.rb up to that point (the Main module and its dispatch, unchanged)
followed by a one-shot entry: one request or one sync pass per run of the module.
"""
import os
import sys

root = sys.argv[1]
source = open(os.path.join(root, "main.rb")).read()
marker = '\nif ARGV.length > 0 && ARGV[0] == "sidekiq"'
head = source[: source.index(marker)]

entry = r'''

# ── one-shot entry for wasm32-wasi (hand-written, see make_wasm_entry.py) ──────
#
# WASM_MODE=request (default): stdin holds one raw HTTP request; stdout gets the status line,
#   the headers, a blank line and the body.
# WASM_MODE=sync: run one pass of the gem's own sync loop (InstantRecord::Client.sync_pass)
#   against SYNC_ENDPOINT; the transport and notifier reach the host through /host/* files.

# ActiveSupport's Hash#deep_stringify_keys, which the gem's sync client calls on parsed JSON and
# the emitted runtime does not carry.
class Hash
  def deep_stringify_keys
    result = {}
    each do |key, value|
      result[key.to_s] = value.is_a?(Hash) ? value.deep_stringify_keys : value
    end
    result
  end
end

Main.configure_default_adapter!
Tep::APP.name = Rails.application.global_id_app
InstantRecord.sync(Issue, ChatUser, Channel, Message)

if (ENV["WASM_MODE"] || "request") == "sync"
  InstantRecord.config.endpoint = ENV["SYNC_ENDPOINT"] || "/instant_record"
  changed = InstantRecord::Client.sync_pass
  $stdout.write((changed ? "changed" : "unchanged") + " pending=" + InstantRecord::Client.pending_count.to_s)
else
  req = Tep::Parser.parse($stdin.read.to_s)
  res = Tep::Response.new
  Tep::APP.dispatch(req, res)
  out = +""
  out << res.status.to_s << "\n"
  res.headers.each { |name, value| out << name.to_s << ": " << value.to_s << "\n" }
  res.header_fields.each { |pair| out << pair[0].to_s << ": " << pair[1].to_s << "\n" }
  res.set_cookies.each { |cookie| out << "Set-Cookie: " << cookie.to_s << "\n" }
  out << "X-File-Path: " << res.file_path << "\n" if res.file_path.length > 0
  out << "\n" << res.body
  $stdout.write(out)
end
'''
open(os.path.join(root, "main_wasm.rb"), "w").write(head + entry)
print("wrote main_wasm.rb:", len(head.splitlines()), "lines of main.rb +", len(entry.splitlines()), "entry lines")
