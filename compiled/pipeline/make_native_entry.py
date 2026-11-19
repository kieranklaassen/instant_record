#!/usr/bin/env python3
"""Write main_native.rb into a single-threaded Spinel tree (make_wasm_tree.py).

usage: make_native_entry.py <tree> <staged app>

main_native.rb is main.rb as the browser build left it, followed by entry_template.py's bridge
and boot filled for a native host. The browser's host is a WASI directory. A native host has
none: the same strings go through native_shim.c, reached from Ruby as NativeHost. Three more
entry points are the phone's own: render and action, for the app's screens (app/screens), and
open, which closes the database and opens another file. The lookup from a screen's name to its
class is written out as a `case`, since nothing can look a constant up at run time, from the
table Ruby prints (native_screens.rb).
"""
import os
import re
import subprocess
import sys

import entry_template

tree, app = sys.argv[1], sys.argv[2]

HOST = '''
# The native host's side of the bridge (native_shim.c).
module NativeHost
  ffi_func :ir_host_take, [:str], :str
  ffi_func :ir_host_give, [:str, :str], :void
end
'''

ENTRIES = '''
  # In: {"screen": name, "params": {...}}. Out: the screen as JSON.
  def self.render
    input = JSON.parse(NativeHost.ir_host_take("in"))
    screen = NativeScreens.find(input["screen"].to_s, InstantRecord::Native::Screen.strings(input["params"]))
    NativeHost.ir_host_give("out", screen.json)
    0
  end

  # In: the same, with "action", the "args" the tapped element carried and
  # the "values" a form's fields held.
  def self.action
    input = JSON.parse(NativeHost.ir_host_take("in"))
    screen = NativeScreens.find(input["screen"].to_s, InstantRecord::Native::Screen.strings(input["params"]))
    screen.perform(input["action"].to_s, InstantRecord::Native::Screen.strings(input["args"]), InstantRecord::Native::Screen.strings(input["values"]))
    0
  end

  # In: the SQLite file to work in from here on. The one open before is closed.
  def self.open
    NativeDatabase.open(NativeHost.ir_host_take("in"))
    0
  end
'''

# A phone's database is a real file that has to survive the app being killed, so it keeps
# SQLite's own journal and locking: the browser's two pragmas for a database held in memory
# are left out. The version the database last had is kept in the database, since there is
# no host file to keep it in and every migration would otherwise run on each launch.
DATABASE = '''
module NativeDatabase
  def self.open(db_path)
    Db.close if @opened
    @opened = true
<<database>>    InstantRecord::Client.forget_database
    0
  end
end
'''

SCREENS = '''
module NativeScreens
  def self.find(name, params)
    case name
<<cases>>    else raise ArgumentError, "No screen named " + name
    end
  end
end
'''


def screens():
    """[(name, class)] for the app's screens, as InstantRecord::Native names them."""
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "native_screens.rb")
    done = subprocess.run(["ruby", script, app], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if done.returncode != 0:
        sys.exit(done.stderr.strip() or "native_screens.rb failed")
    return [tuple(line.split()) for line in done.stdout.splitlines()]


def indent(text, by):
    return "".join(by + line if line.strip() else line for line in text.splitlines(keepends=True))


source = open(os.path.join(tree, "main_wasm.rb")).read()
if source.count(entry_template.BANNER) != 1:
    sys.exit("main_wasm.rb has no entry to start from")
head = source[: source.index(entry_template.BANNER)]

found = screens()
cases = "".join(f'    when "{name}" then {cls}.new(params)\n' for name, cls in found)
previous = 'InstantRecord::SyncMetadata.get("schema_version").to_s'
applied = 'InstantRecord::SyncMetadata.set("schema_version", "<<version>>")'
database = entry_template.database(["cache_size = -4000"], entry_template.migrations(previous, applied))
entry = (
    entry_template.BANNER + " for a native host (see make_native_entry.py) ─────────\n"
    + entry_template.PRELUDE
    + HOST
    + entry_template.fill(SCREENS, {"cases": cases})
    + entry_template.bridge("NativeBridge", lambda name: f'NativeHost.ir_host_take("{name}")', lambda name: f'NativeHost.ir_host_give("{name}", ', ENTRIES)
    + entry_template.fill(DATABASE, {"database": indent(database, "    ")})
    + "\nNativeDatabase.open(Main.default_db_path)\n"
    # The browser's page holds the event stream and the worker never polls. Here a sync pass
    # pulls through the host, and a host that also fetches changes hands them to "stream".
    + entry_template.start(False, "# A sync pass pulls through the host: Client#sync_pass handles bootstrap, outbox drain and the poll.")
)
open(os.path.join(tree, "main_native.rb"), "w").write(head + entry)

# The gem's worker transport and notifier speak to the same host.
seams = 0
for base, _dirs, files in os.walk(os.path.join(tree, "app/models/instant_record/client")):
    for name in files:
        path = os.path.join(base, name)
        text = open(path).read()
        changed = re.sub(r'File\.read\("/host/(\w+)"\)', r'NativeHost.ir_host_take("\1")', text)
        changed = re.sub(r'File\.write\("/host/(\w+)", ', r'NativeHost.ir_host_give("\1", ', changed)
        changed = re.sub(r'File\.write\((?:[\w:]+::)?REQUEST, ', 'NativeHost.ir_host_give("request", ', changed)
        changed = re.sub(r'File\.read\((?:[\w:]+::)?RESPONSE\)', 'NativeHost.ir_host_take("response")', changed)
        if changed != text:
            open(path, "w").write(changed)
        seams += "NativeHost." in changed
if seams != 2:
    sys.exit(f"expected the transport and the notifier to reach the host, found {seams} file(s)")
print("wrote main_native.rb with screens:", ", ".join(name for name, _cls in found) or "none")
