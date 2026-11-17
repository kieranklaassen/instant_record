#!/usr/bin/env python3
"""Copy an emitted Spinel project and make it buildable for wasm32-wasi.

Spinel refuses any program that names Thread, Mutex, Queue or ConditionVariable on that target,
and Roundhouse's Spinel runtime is written for a threaded native server (connection pool locks,
thread-local request state, background loops). A one-shot wasm run is single-threaded, so the
copy renames those four constants in the runtime to single-threaded stand-ins defined in
runtime/wasm_threads.rb: a lock that just yields, thread-locals in one hash, and background
threads that never start. The application code (app/) is not touched.
"""
import os
import re
import shutil
import sys

source, target = sys.argv[1], sys.argv[2]
shutil.rmtree(target, ignore_errors=True)
shutil.copytree(source, target, ignore=shutil.ignore_patterns("build", "storage", "node_modules", "e2e", "test"))

RENAMES = [(re.compile(r"\b" + name + r"\b"), "Wasm" + name) for name in ["Thread", "Mutex", "Queue", "ConditionVariable", "Fiber"]]
touched = 0
paths = [os.path.join(target, name) for name in ["boot.rb", "main_wasm.rb"]]
for folder in ["runtime", "config"]:
    for base, _dirs, names in os.walk(os.path.join(target, folder)):
        paths += [os.path.join(base, name) for name in names if name.endswith(".rb")]
for path in paths:
    text = open(path).read()
    renamed = text
    for pattern, replacement in RENAMES:
        renamed = pattern.sub(replacement, renamed)
    if renamed != text:
        open(path, "w").write(renamed)
        touched += 1

open(os.path.join(target, "runtime/wasm_threads.rb"), "w").write('''# Hand-written (see make_wasm_tree.py): single-threaded stand-ins for the threading classes the
# emitted runtime uses. One wasm run handles one request on one thread, so a lock has nothing to
# exclude, a thread-local is a plain slot, and a background thread is never started.
class WasmThread
  def self.current
    @current ||= WasmThread.new
  end

  def self.pass
    nil
  end

  def initialize(a = nil, b = nil, &block)
    @locals = {}
  end

  def [](key)
    @locals[key]
  end

  def []=(key, value)
    @locals[key] = value
  end

  def key?(key)
    @locals.key?(key)
  end

  def join(limit = nil)
    self
  end

  def alive?
    false
  end

  def kill
    self
  end
end

# WASI has no stack switching, so a Fiber cannot be created. The runtime only builds them for its
# fiber-per-connection server, which a one-shot run never starts.
class WasmFiber
  def self.yield(value = nil)
    nil
  end

  def initialize(&block)
    @started = false
  end

  def resume(value = nil)
    nil
  end

  def alive?
    false
  end
end

class WasmMutex
  def synchronize
    yield
  end

  def lock
    self
  end

  def unlock
    self
  end

  def locked?
    false
  end

  def owned?
    true
  end

  def try_lock
    true
  end
end

class WasmConditionVariable
  def wait(mutex = nil, timeout = nil)
    self
  end

  def signal
    self
  end

  def broadcast
    self
  end
end
''')

# Spinel's bundled `timeout` library is built on Thread. Nothing in a one-shot run can time out,
# so the runtime's `require "timeout"` goes and a stand-in that just runs the block takes its place.
for path in paths:
    text = open(path).read()
    if 'require "timeout"' in text:
        open(path, "w").write(text.replace('require "timeout"', '# require "timeout"  (wasm: see runtime/wasm_threads.rb)'))
with open(os.path.join(target, "runtime/wasm_threads.rb"), "a") as shim:
    shim.write('''
module Timeout
  class Error < RuntimeError
  end

  def self.timeout(sec, klass = nil, message = nil)
    yield(sec)
  end
end
''')

# OpenSSL has no wasm build in Spinel. The emitted runtime needs it only for AES-256-GCM
# (encrypted cookies and attributes), which this app does not use; HMAC, SHA and random bytes
# come from Spinel's own crypto and stay. The two AES methods become refusals.
digest = os.path.join(target, "runtime/message_digest.rb")
text = open(digest).read()
start = text.index("  def self.aes_256_gcm_encrypt")
text = text[:start].replace('require "openssl"', '# require "openssl"  (wasm: no OpenSSL build)') + '''  def self.aes_256_gcm_encrypt(key, iv, plain)
    raise NotImplementedError, "AES-256-GCM is not available in the wasm build"
  end

  def self.aes_256_gcm_decrypt(key, iv, ct, tag)
    raise NotImplementedError, "AES-256-GCM is not available in the wasm build"
  end
end
'''
open(digest, "w").write(text)

# The runtime binds two SQLite calls with `long`, which is 32 bits on wasm32 while SQLite's own
# signatures are 64-bit. They go through 32-bit entry points in sqlite/rh_shim.c instead.
db = os.path.join(target, "runtime/db.rb")
text = open(db).read()
for name in ["sqlite3_bind_int64", "sqlite3_last_insert_rowid"]:
    text = text.replace(name, "rh_" + name)
open(db, "w").write(text)

# Emitted models cast integers and strings on mass assignment but pass datetime values straight
# through, so assign_attributes with the server's ISO 8601 strings (what the gem's sync client
# does, and what Rails accepts) raises. Cast them with the runtime's own cast_datetime.
casts = 0
for base, _dirs, names in os.walk(os.path.join(target, "app/models")):
    for name in names:
        if not name.endswith(".rb"):
            continue
        path = os.path.join(base, name)
        text = open(path).read()
        fixed, count = re.subn(
            r'(if name == "(\w+_at)"\n\s+if respond_to\?\(:\2=\)\n\s+self\.\2 = )value\n',
            r"\1ActiveSupport.cast_datetime(value)\n", text)
        if count:
            open(path, "w").write(fixed)
            casts += count

# The emitted ActiveRecord base has changed? but not Rails' `changed` (the names of the pending
# columns), which the gem's sync client reads. Same source of truth, one more reader.
base = os.path.join(target, "runtime/active_record/base.rb")
text = open(base).read()
anchor = "    def has_changes_to_save?\n"
assert anchor in text
open(base, "w").write(text.replace(anchor, '''    def changed
      changes = changes_to_save
      changes.keys.map { |name| name.to_s }
    end

''' + anchor, 1))

# Roundhouse lowers `each_with_index` in a view as if its block were captured: every row is built
# into a buffer that is then dropped instead of appended to the page. Append it.
for base, _dirs, names in os.walk(os.path.join(target, "app/views")):
    for name in names:
        if not name.endswith(".rb"):
            continue
        path = os.path.join(base, name)
        text = open(path).read()
        if "each_with_index" in text and "ActionView::ViewHelpers.raw(_cap)" in text:
            open(path, "w").write(text.replace("ActionView::ViewHelpers.raw(_cap)", "io << _cap"))

# Roundhouse emits `button_to ..., form: { data: {...} }` with the form: option as an attribute of
# the <button>. In HTML that `form` attribute detaches the button from its own form, so the
# button does nothing. Move the data attributes to the <form>, where Rails puts them.
for base, _dirs, names in os.walk(os.path.join(target, "app/views")):
    for name in names:
        if not name.endswith(".rb"):
            continue
        path = os.path.join(base, name)
        text = open(path).read()
        bogus = '#{ActionView::ViewHelpers.tag_attr("form", { data: { turbo: false, action: "submit->issues#submit" } })}'
        if bogus in text:
            text = text.replace(bogus, "")
            text = text.replace('class=\\"#{"button_to"}\\">', 'class=\\"#{"button_to"}\\" data-turbo=\\"false\\" data-action=\\"submit-&gt;issues#submit\\">')
            open(path, "w").write(text)

# Roundhouse turns @channel into a parameter named `channel`, and the sidebar's own loop variable
# is also `channel`, so "is this the open channel" compares a row with itself and every channel
# is marked active. Rename the loop variable in the emitted partial.
sidebar = os.path.join(target, "app/views/slack/channels/_sidebar.rb")
text = open(sidebar).read()
start = text.index("channels.each do |channel|")
stop = text.index("dms.each do", start)
loop = re.sub(r"\bchannel\b", "channel_row", text[start:stop]).replace("channel_row == channel_row", "channel_row == channel")
open(sidebar, "w").write(text[:start] + loop + text[stop:])

boot = os.path.join(target, "boot.rb")
text = open(boot).read()
first = re.search(r"^require(_relative)? ", text, flags=re.M).start()  # the first real require line
open(boot, "w").write(text[:first] + 'require_relative "runtime/wasm_threads"\n' + text[first:])
print("wasm tree:", touched, "runtime files had threading constants renamed")
