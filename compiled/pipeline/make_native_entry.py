#!/usr/bin/env python3
"""Write main_native.rb into a single-threaded Spinel tree (make_wasm_tree.py).

usage: make_native_entry.py <tree> <staged app> <gem source>

main_native.rb is main_wasm.rb with two changes. The browser's host is a WASI filesystem, so its
entry trades strings through files under /host. A native host has no such directory: the same
strings go through native_shim.c, reached from Ruby as NativeHost. And the app's screens
(app/screens) get two more entry points, render and action, with the lookup from a screen's name
to its class written out as a `case`, since nothing can look a constant up at run time. Opening the
database becomes a method, so that the open_database entry can close one file and open another.
"""
import os
import re
import subprocess
import sys

tree, app, gem = sys.argv[1], sys.argv[2], sys.argv[3]

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
    """Each screen class in app/screens with the name it answers to. The name comes from the gem's
    own rule (InstantRecord::Native.name_of), so there is one rule and Ruby holds it. A file that
    declares no screen, such as a module the screens share, is carried along and is not a screen."""
    folder = os.path.join(app, "app/screens")
    classes = []
    for name in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
        if name.endswith(".rb"):
            classes += re.findall(r"^class (\w+Screen) <", open(os.path.join(folder, name)).read(), re.M)
    if not classes:
        return []
    rule = os.path.join(gem, "lib/instant_record/native.rb")
    named = subprocess.run(["ruby", "-I", os.path.join(gem, "lib"), "-r", rule, "-e", "puts ARGV.map { |name| InstantRecord::Native.name_of(name) }", *classes],
                           check=True, stdout=subprocess.PIPE, text=True).stdout.split()
    return list(zip(named, classes))


found = screens()
cases = "".join(f'    when "{name}" then {klass}.new(params)\n' for name, klass in found)
entry = f'''
module NativeScreens
  def self.find(name, params)
    case name
{cases}    else raise ArgumentError, "No screen named " + name
    end
  end
end

module NativeBridge
  # A JSON object of names and values, as the strings a screen reads.
  def self.strings(object)
    out = {{}}
    object.each {{ |name, value| out[name.to_s] = value.to_s }}
    out
  end

  # In: {{"screen": name, "params": {{...}}}}. Out: the screen as JSON.
  def self.render
    input = JSON.parse(NativeHost.ir_host_take("in"))
    NativeHost.ir_host_give("out", NativeScreens.find(input["screen"].to_s, NativeBridge.strings(input["params"])).json)
    0
  end

  # In: the same, with "action" and the params it carries as "with".
  def self.action
    input = JSON.parse(NativeHost.ir_host_take("in"))
    NativeScreens.find(input["screen"].to_s, NativeBridge.strings(input["params"])).perform(input["action"].to_s, NativeBridge.strings(input["with"]))
    0
  end

  # In: the path of another SQLite file. The open one is closed first, since
  # a database syncs with one address and an app that changes account
  # changes file.
  def self.open_database
    path = NativeHost.ir_host_take("in")
    previous = NativeDatabase.path
    Db.close
    begin
      NativeDatabase.open(path)
    rescue StandardError => error
      # Go back to the file that was open, so the app is not left with none.
      NativeDatabase.open(previous)
      raise error
    end
    0
  end
end
'''

source = open(os.path.join(tree, "main_wasm.rb")).read()

# The browser's page holds the event stream and the worker never polls. Here a sync pass
# pulls through the host, and a host that also holds a stream hands its batches to "stream".
streaming = "InstantRecord::Client.streaming = true\n"
if source.count(streaming) != 1:
    sys.exit("main_wasm.rb does not turn streaming on where expected")
source = source.replace(streaming, "InstantRecord::Client.streaming = false\n")
marker = "\nmodule WasmBridge\n"
if source.count(marker) != 1:
    sys.exit("main_wasm.rb has no WasmBridge to start from")
source = through_host(source).replace("WasmBridge", "NativeBridge")
marker = marker.replace("WasmBridge", "NativeBridge")
boot = "\ndb_path = Main.default_db_path\n"
if source.count(boot) != 1:
    sys.exit("main_wasm.rb does not open its database where expected")
source = source.replace(marker, HOST + marker).replace(boot, entry + boot)

# Everything from opening the file to the first line that is about the app and not its database
# becomes NativeDatabase.open, called once here at boot and again by the open_database entry.
start = source.index(boot) + 1
finish = source.index("\nTep::APP.name = ", start) + 1
if finish == 0:
    sys.exit("main_wasm.rb does not name the app after opening its database, where expected")
opening = source[start:finish].replace("db_path = Main.default_db_path\n", "", 1)
# A consumer app's boot runs the migrations a restored database has not had. The browser's host
# tells it the version the database is at. A native host has no such thing to tell, so the
# version is kept in the database itself and written once the pending statements have run.
versions = re.findall(r'previous < "(\d{20})"', opening)
if versions:
    asked = 'previous = NativeHost.ir_host_take("schema_version")\n'
    if opening.count(asked) != 1:
        sys.exit("main_wasm.rb does not ask the host for the schema version where expected")
    opening = opening.replace(asked, 'previous = InstantRecord::SyncMetadata.get("schema_version").to_s\n')
    opening += f'InstantRecord::SyncMetadata.set("schema_version", "{max(versions)}")\n'
method = "module NativeDatabase\n  def self.path = @path.to_s\n\n  def self.open(db_path)\n    @path = db_path\n" + "".join("    " + line + "\n" if line else "\n" for line in opening.rstrip("\n").split("\n")) + "  end\nend\nNativeDatabase.open(Main.default_db_path)\n"
source = source[:start] + method + source[finish:]
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
        changed = re.sub(r'File\.write\((?:[\w:]+::)?REQUEST, ', 'NativeHost.ir_host_give("request", ', changed)
        changed = re.sub(r'File\.read\((?:[\w:]+::)?RESPONSE\)', 'NativeHost.ir_host_take("response")', changed)
        if changed != text:
            open(path, "w").write(changed)
        seams += "NativeHost." in changed
if seams != 2:
    sys.exit(f"expected the transport and the notifier to reach the host, found {seams} file(s)")
print("wrote main_native.rb with screens:", ", ".join(name for name, _klass in found) or "none")
