"""The entry both compiled builds end with: the bridge a host calls, and the boot.

The browser's entry (make_wasm_entry.py) and the native one (make_native_entry.py) each fill
this with how their host trades strings, whether the host holds the event stream, the pragmas
their database wants and where the applied schema version is kept. What they share is written
once, here.
"""
import json
import os
import re
import sys

# Where an entry begins in the file it is written to. Everything before it is main.rb.
BANNER = "\n\n# ── persistent reactor entry"
DEMO_MODELS = ["Issue", "ChatUser", "Channel", "Message", "Note", "MailEntry", "AssistantChat", "AssistantTurn", "AuthNote"]

PRELUDE = r'''
class Hash
  def deep_stringify_keys
    result = {}
    each do |key, value|
      result[key.to_s] = value.is_a?(Hash) ? value.deep_stringify_keys : value
    end
    result
  end
end
'''

# <<read:NAME>> and <<write:NAME>> are the host's two calls, filled by the entry.
BRIDGE = r'''
module <<bridge>>
  def self.handle_request
    req = Tep::Parser.parse(<<read:in>>)
    res = Tep::Response.new
    Tep::APP.dispatch(req, res)
    out = +""
    out << res.status.to_s << "\n"
    res.headers.each { |name, value| out << name.to_s << ": " << value.to_s << "\n" }
    res.header_fields.each { |pair| out << pair[0].to_s << ": " << pair[1].to_s << "\n" }
    res.set_cookies.each { |cookie| out << "Set-Cookie: " << cookie.to_s << "\n" }
    out << "X-File-Path: " << res.file_path << "\n" if res.file_path.length > 0
    out << "\n" << res.body
    <<write:out>>out)
    0
  end

  # Capture the exact outgoing batch before the worker yields to browser requests.
  def self.sync_plan
    mutations = InstantRecord::Client.pending_mutations
    push = mutations.empty? ? "" : JSON.generate(InstantRecord::Client.mutations_payload(mutations))
    <<write:out>>JSON.generate({ push: push, bootstrap: !InstantRecord::Client.bootstrapped? }))
    0
  end

  def self.handle_sync
    endpoint = <<read:in>>.strip
    InstantRecord.config.endpoint = endpoint if endpoint.length > 0
    changed = InstantRecord::Client.sync_pass
    <<write:out>>(changed ? "changed" : "unchanged") + " pending=" + InstantRecord::Client.pending_count.to_s + " cursor=" + InstantRecord::Client.cursor.to_s)
    0
  end

  def self.handle_stream
    applied = InstantRecord::Client.consume_stream(<<read:in>>)
    # A batch can be the server's reset, after which there is no cursor to report.
    <<write:out>>"applied=" + applied.to_s + " cursor=" + InstantRecord::Client.cursor.to_s + " bootstrap=" + (InstantRecord::Client.bootstrapped? ? "ready" : "needed"))
    0
  end

  # History has its own keyset and must not advance the live change cursor.
  # Keep the page receipt in the same SQLite transaction as its records.
  def self.history
    input = JSON.parse(<<read:in>>)
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
    <<write:out>>JSON.generate(result))
    0
  end

  def self.cursor
    key = InstantRecord::Client.identity_key
    <<write:out>>"cursor=" + InstantRecord::Client.cursor.to_s + " pending=" + InstantRecord::Client.pending_count.to_s + " bootstrap=" + (InstantRecord::Client.bootstrapped? ? "ready" : "needed") + " identity=" + (key.nil? ? "" : key))
    0
  end
<<entries>>end
'''

# Opens the database at db_path: its tables when it is new, the migrations it has not had,
# and one rehydration when the set of synced models changed.
DATABASE = r'''restored = File.exist?(db_path) && File.size(db_path) > 0
SqliteAdapter.configure(db_path)
ActiveRecord.adapter = SqliteAdapter
<<pragmas>>Schema.statements.each { |sql| SqliteAdapter.execute_ddl(sql) } unless restored
<<migrations>>
# Earlier demos saved a cursor before Note was a synced model. Rehydrate once
# on a model-set change, preserving all local rows and pending mutations.
model_set = "<<model_set>>"
if InstantRecord::SyncMetadata.get("compiled_models") != model_set
  Schema.statements.each { |sql| SqliteAdapter.execute_ddl(sql) } if restored
  InstantRecord::SyncMetadata.where(key: "cursor").delete_all if restored
  InstantRecord::SyncMetadata.set("compiled_models", model_set)
end
'''

START = r'''Tep::APP.name = Rails.application.global_id_app
<<windows>>InstantRecord.sync(<<models>>)
<<streaming>>
'''


def app_models():
    """The models this build syncs: the demo's, or the ones the app declared."""
    if not os.environ.get("INSTANT_RECORD_APP"):
        return DEMO_MODELS
    models = json.loads(os.environ["INSTANT_RECORD_MODELS"])
    if not models or not all(re.fullmatch(r"[A-Z]\w*(?:::[A-Z]\w*)*", name) for name in models):
        sys.exit("Declare at least one named model that includes InstantRecord::Syncable.")
    return models


def migrations(previous, applied=""):
    """Ruby that runs the app's pending DDL and backfills on a database that was restored.

    `previous` is the Ruby expression for the version the database last had. `applied` is a
    template for a statement that records the version afterwards, for a host that keeps it
    in the database. Returns "" for the demo, which has no migration plan.

    The steps run on the visitor's own SQLite rows, before model discovery or the first
    request. WASI Spinel integers are 32-bit, so versions are compared as fixed-width decimal
    strings and a normal 14-digit Rails migration timestamp never overflows.
    """
    if not os.environ.get("INSTANT_RECORD_APP"):
        return ""
    with open(os.environ["INSTANT_RECORD_MIGRATION_PLAN"]) as file:
        plan = json.load(file)
    steps = ["if restored", f"  previous = {previous}"]
    for version, statements in plan["migrations"].items():
        steps.append(f'  if previous < "{int(version):020d}"')
        for sql in statements:
            literal = json.dumps(sql, ensure_ascii=False).replace("#{", "\\#{").replace("#@", "\\#@").replace("#$", "\\#$")
            steps.append("    Db.exec(" + literal + ")")
        steps.append("  end")
    steps.append("end")
    if applied:
        latest = max((int(version) for version in plan["migrations"]), default=0)
        steps.append(applied.replace("<<version>>", f"{latest:020d}"))
    return "\n" + "\n".join(steps) + "\n"


def fill(text, values, read=None, write=None):
    """Replace each <<name>> with its value, and the host's two calls when they are given."""
    for name, value in values.items():
        text = text.replace(f"<<{name}>>", value)
    if read:
        text = re.sub(r"<<read:(\w+)>>", lambda found: read(found.group(1)), text)
        text = re.sub(r"<<write:(\w+)>>", lambda found: write(found.group(1)), text)
    left = re.search(r"<<[\w:]+>>", text)
    if left:
        sys.exit(f"entry_template: nothing filled {left.group(0)}")
    return text


def bridge(name, read, write, entries=""):
    return fill(BRIDGE, {"bridge": name, "entries": entries}, read, write)


def database(pragmas, steps):
    models = app_models()
    lines = "".join(f'SqliteAdapter.execute_ddl("PRAGMA {pragma}")\n' for pragma in pragmas)
    return fill(DATABASE, {"pragmas": lines, "migrations": steps, "model_set": ",".join(sorted(models))})


def start(streaming, comment):
    models = app_models()
    windows = "" if os.environ.get("INSTANT_RECORD_APP") else "Message.sync_window(limit: 50, partition_by: :channel_id)\n"
    flag = f"{comment}\nInstantRecord::Client.streaming = {'true' if streaming else 'false'}"
    return fill(START, {"windows": windows, "models": ", ".join(models), "streaming": flag})
