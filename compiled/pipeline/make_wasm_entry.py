#!/usr/bin/env python3
"""Write main_wasm.rb into an emitted Spinel project.

The emitted main.rb ends by starting a threaded TCP server, and WASI has neither threads nor
sockets. main_wasm.rb is main.rb up to that point (the Main module and its dispatch, unchanged)
followed by a persistent WASI reactor bridge: boot once (SQLite + runtime stay warm), then serve
HTTP requests, outbox drains, and async-fetched change batches through /host/in and /host/out.
The bridge and the boot are entry_template.py's, filled here for a host that is a WASI directory.
"""
import os
import shutil
import sys

import entry_template

root = sys.argv[1]
if not os.environ.get("INSTANT_RECORD_APP"):
    shutil.copyfile(os.path.join(os.path.dirname(__file__), "sqlite_release.rb"),
                os.path.join(root, "app/models/release.rb"))
source = open(os.path.join(root, "main.rb")).read()
marker = '\nif ARGV.length > 0 && ARGV[0] == "sidekiq"'
head = source[: source.index(marker)]

# The worker commits the migrated image and its version together only after boot succeeds,
# so the version the database last had is a file the worker wrote.
entry = (
    entry_template.BANNER + " for wasm32-wasi (see make_wasm_entry.py) ─────────\n"
    + entry_template.PRELUDE
    + entry_template.bridge("WasmBridge", lambda name: f'File.read("/host/{name}")', lambda name: f'File.write("/host/{name}", ')
    + "\ndb_path = Main.default_db_path\n"
    + entry_template.database(["locking_mode = EXCLUSIVE", "journal_mode = MEMORY", "cache_size = -4000"],
                              entry_template.migrations('File.read("/host/schema_version")'))
    + entry_template.start(True, "# JS worker owns non-blocking inbound polling; Client#sync_pass handles bootstrap + outbox drain.")
)
open(os.path.join(root, "main_wasm.rb"), "w").write(head + entry)
print("wrote main_wasm.rb:", len(head.splitlines()), "lines of main.rb +", len(entry.splitlines()), "entry lines")
