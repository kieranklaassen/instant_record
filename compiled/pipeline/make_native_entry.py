#!/usr/bin/env python3
"""Write main_native.rb into a single-threaded Spinel tree (make_wasm_tree.py).

usage: make_native_entry.py <tree> <staged app>

main_native.rb is main_wasm.rb with two changes. The browser's host is a WASI filesystem, so its
entry trades strings through files under /host. A native host has no such directory: the same
strings go through native_shim.c, reached from Ruby as NativeHost. And the app's screens
(app/screens) get two more entry points, render and action, with the lookup from a screen's name
to its class written out as a `case`, since nothing can look a constant up at run time.
"""
import os
import re
import sys

tree, app = sys.argv[1], sys.argv[2]

HOST = '''
# The native host's side of the bridge (native_shim.c).
module NativeHost
  ffi_func :ir_host_take, [:str], :str
  ffi_func :ir_host_give, [:str, :str], :void
end
'''


def through_host(source):
    source = re.sub(r'File\.read\("/host/(\w+)"\)', r'NativeHost.ir_host_take("\1")', source)
    return re.sub(r'File\.write\("/host/(\w+)", ', r'NativeHost.ir_host_give("\1", ', source)


def screens():
    folder = os.path.join(app, "app/screens")
    names = sorted(name[:-len("_screen.rb")] for name in os.listdir(folder) if name.endswith("_screen.rb")) if os.path.isdir(folder) else []
    if not all(re.fullmatch(r"[a-z][a-z0-9_]*", name) for name in names):
        sys.exit("Name each file in app/screens <name>_screen.rb.")
    return names


def camelize(name):
    return "".join(part.capitalize() for part in name.split("_"))


names = screens()
cases = "".join(f'    when "{name}" then {camelize(name)}Screen.new(arg)\n' for name in names)
entry = f'''
module NativeScreens
  def self.find(name, arg)
    case name
{cases}    else InstantRecord::Native::Screen.new(arg)
    end
  end
end

module NativeBridge
  # In: the screen's name, then its argument, one to a line. Out: the screen as JSON.
  def self.render
    input = NativeHost.ir_host_take("in").split("\\n")
    NativeHost.ir_host_give("out", NativeScreens.find(input[0].to_s, input[1].to_s).json)
    0
  end

  # In: the screen's name and argument, then the action and its argument.
  def self.action
    input = NativeHost.ir_host_take("in").split("\\n")
    NativeScreens.find(input[0].to_s, input[1].to_s).perform(input[2].to_s, input[3].to_s)
    0
  end
end
'''

source = open(os.path.join(tree, "main_wasm.rb")).read()
marker = "\nmodule WasmBridge\n"
if source.count(marker) != 1:
    sys.exit("main_wasm.rb has no WasmBridge to start from")
source = through_host(source).replace("WasmBridge", "NativeBridge")
marker = marker.replace("WasmBridge", "NativeBridge")
boot = "\ndb_path = Main.default_db_path\n"
if source.count(boot) != 1:
    sys.exit("main_wasm.rb does not open its database where expected")
source = source.replace(marker, HOST + marker).replace(boot, entry + boot)
# The browser keeps its database in memory and saves snapshots, so it locks the file to one
# connection and journals in memory. A phone's database is a real file that has to survive the
# app being killed: it keeps SQLite's own journal, and the runtime's connections share it.
for pragma in ("locking_mode = EXCLUSIVE", "journal_mode = MEMORY"):
    line = f'SqliteAdapter.execute_ddl("PRAGMA {pragma}")\n'
    if source.count(line) != 1:
        sys.exit(f"main_wasm.rb does not set {pragma} where expected")
    source = source.replace(line, "")
open(os.path.join(tree, "main_native.rb"), "w").write(source)

# The gem's worker transport and notifier speak to the same host.
seams = 0
for base, _dirs, files in os.walk(os.path.join(tree, "app/models/instant_record/client")):
    for name in files:
        path = os.path.join(base, name)
        text = open(path).read()
        changed = through_host(text)
        # Roundhouse spells the two constants out in full.
        changed = re.sub(r'File\.write\((?:[\w:]+::)?REQUEST, ', 'NativeHost.ir_host_give("request", ', changed)
        changed = re.sub(r'File\.read\((?:[\w:]+::)?RESPONSE\)', 'NativeHost.ir_host_take("response")', changed)
        if changed != text:
            open(path, "w").write(changed)
        seams += "NativeHost." in changed
if seams != 2:
    sys.exit(f"expected the transport and the notifier to reach the host, found {seams} file(s)")
print("wrote main_native.rb with screens:", ", ".join(names) or "none")
