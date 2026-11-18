#!/usr/bin/env python3
"""Vendor the instant_record gem's own Ruby into the carved app's lib/, then apply the host seams.

Everything not listed under SEAMS is the gem's file, byte for byte. The seams are the places
where the gem talks to ruby.wasm's JavaScript bridge or leans on runtime metaprogramming.
"""
import hashlib
import os
import shutil
import sys

gem, app = sys.argv[1], sys.argv[2]
lib = os.path.join(app, "lib")

COPY = [
    "lib/instant_record.rb",
    "lib/instant_record/version.rb",
    "lib/instant_record/configuration.rb",
    "lib/instant_record/runtime_scoped.rb",
    "lib/instant_record/syncable.rb",
    "lib/instant_record/outbox_mutation.rb",
    "lib/instant_record/sync_metadata.rb",
    "lib/instant_record/sync_window.rb",
    "lib/instant_record/client.rb",
    "lib/instant_record/client/transport.rb",
    "lib/instant_record/client/notifier.rb",
    "lib/instant_record/client/instrumentation.rb",
]
shutil.rmtree(os.path.join(lib, "instant_record"), ignore_errors=True)
for rel in COPY:
    target = os.path.join(app, rel)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    shutil.copy(os.path.join(gem, rel), target)
os.makedirs(os.path.join(app, "app/models/instant_record"), exist_ok=True)
shutil.copy(os.path.join(gem, "app/models/instant_record/change.rb"), os.path.join(app, "app/models/instant_record/change.rb"))


def edit(rel, old, new, count=1):
    path = os.path.join(app, rel)
    source = open(path).read()
    if source.count(old) < 1:
        if new and new in source:
            return  # already applied on an earlier run (app files are edited in place)
        raise SystemExit(f"seam did not apply: {rel}: {old[:60]!r}")
    open(path, "w").write(source.replace(old, new, count))


def cut(rel, start, end, replacement):
    """Replace everything from `start` up to (not including) `end`."""
    path = os.path.join(app, rel)
    source = open(path).read()
    a = source.index(start)
    b = source.index(end, a)
    open(path, "w").write(source[:a] + replacement + source[b:])


# ── SEAMS ────────────────────────────────────────────────────────────────────

# 1. Runtime detection. The gem asks wasmify-rails' Kernel#on_wasm?; this build is always the browser.
edit("lib/instant_record.rb", "      on_wasm?\n", "      true\n")
edit("lib/instant_record.rb", 'require "wasmify-rails" # browser build tasks + PGlite adapter; inert outside wasm builds\n', "")
edit("lib/instant_record.rb", 'require "instant_record/engine" if defined?(Rails::Engine)\n', "")

# 2. Model discovery. ActiveRecord::Base.descendants has no ahead-of-time counterpart; the gem's own
#    explicit allowlist (InstantRecord.sync) takes its place, set in wasm_main.rb.
cut("lib/instant_record.rb", "      ActiveRecord::Base.descendants.select do |model|", "    end\n\n    # One record's attributes as they cross the wire", "      []\n")
edit("lib/instant_record.rb", "      klass = record_type.to_s.safe_constantize\n      klass if klass.respond_to?(:instant_record_syncable?) && klass.instant_record_syncable?\n", "      nil\n")

# 3. Local schema. The gem migrates PGlite at boot through ActiveRecord::MigrationContext; here the
#    schema is created from db/schema.rb by the emitted runtime.
edit("lib/instant_record.rb", "    def prepare_database! = LocalSchema.prepare!\n", "    def prepare_database! = nil\n")

# 4. server_only / browser_only are class_eval(&block). In a browser-only build server_only is a
#    no-op by definition; browser_only's one use in the demo (skip_forgery_protection) is dropped.
open(os.path.join(app, "lib/instant_record/runtime_scoped.rb"), "w").write('''module InstantRecord
  # Host seam (see vendor_gem.py): the gem evaluates these blocks with class_eval, which cannot be
  # compiled ahead of time. This build is the browser, so server_only never runs.
  module RuntimeScoped
    def server_only(&block)
      nil
    end

    def browser_only(&block)
      nil
    end
  end
end
''')

# 5. Transport. The gem's JsFetch drives the JS fetch API through ruby.wasm's `js` gem. Here the
#    host answers through two files: the request is written to one, the response read from the other.
#    SseParser above it is the gem's, unchanged.
cut("lib/instant_record/client/transport.rb", "      # Browser implementation over the JS fetch API", "    end\n  end\nend\n", '''      # Host seam (see vendor_gem.py): same class name and methods as the gem's JS-interop
      # transport, so client.rb is untouched. The host (a WASI shim in a worker) performs the
      # HTTP request when the response file is read.
      class JsFetch
        REQUEST = "/host/request".freeze
        RESPONSE = "/host/response".freeze

        def get_json(path)
          JSON.parse(exchange("GET", path, ""))
        end

        def post_json(path, payload)
          JSON.parse(exchange("POST", path, JSON.generate(payload)))
        end

        # The host returns the whole catch-up stream at once (the loop polls with window=0).
        def each_event(path, &block)
          parser = SseParser.new(&block)
          parser.feed(exchange("GET", path, ""))
        end

        private

        # Request file: first line "METHOD URL", then the body. Response file: first line the
        # status, then the body. Status 0 is a network failure.
        def exchange(method, path, body)
          File.write(REQUEST, "#{method} #{InstantRecord.config.endpoint}#{path}\\n#{body}")
          response = File.read(RESPONSE)
          newline = response.index("\\n") || response.length
          status = response[0, newline].to_i
          raise Error, "#{method} #{path} -> #{status}" unless status >= 200 && status < 300

          response[(newline + 1)..] || ""
        end
      end
''')

# 6. Notifier. The gem posts to the service worker's clients through JS; here it writes a marker
#    file the host watches.
open(os.path.join(app, "lib/instant_record/client/notifier.rb"), "w").write('''module InstantRecord
  module Client
    module Notifier
      # Host seam (see vendor_gem.py): same class name as the gem's JS-interop notifier.
      class JsClients
        def records_changed
          File.write("/host/notify", "records_changed")
        end
      end
    end
  end
end
''')

# 7. The compiled worker reports requests and sync results directly to the inspector.
open(os.path.join(app, "lib/instant_record/client/instrumentation.rb"), "w").write('''module InstantRecord
  module Client
    # The worker owns inspector delivery in the compiled runtime.
    module Instrumentation
      def self.attach
        nil
      end
    end
  end
end
''')

# 8. Roundhouse folds a concern's `included do` callbacks and `class_methods` into the including
#    models only when the concern is a top-level module under app/models/concerns. The gem's
#    InstantRecord::Syncable is therefore un-nested to ::Syncable (body unchanged), and the four
#    models' include lines follow.
path = os.path.join(app, "lib/instant_record/syncable.rb")
lines = open(path).read().rstrip("\n").split("\n")
start = lines.index("module InstantRecord")
assert lines[-1] == "end"
body = lines[:start] + [line[2:] if line.startswith("  ") else line for line in lines[start + 1:-1]]
os.makedirs(os.path.join(app, "app/models/concerns"), exist_ok=True)
shutil.rmtree(os.path.join(app, "app/models/concerns/instant_record"), ignore_errors=True)
open(os.path.join(app, "app/models/concerns/syncable.rb"), "w").write("\n".join(body) + "\n")
os.unlink(path)
from pathlib import Path
import re
for target in Path(app, "app/models").rglob("*.rb"):
    source = target.read_text()
    adapted = source.replace("include InstantRecord::Syncable", "include Syncable")
    adapted = re.sub(r"\n( *)server_only do\n.*?\n\1end\n", "\n", adapted, flags=re.S)
    if adapted != source:
        target.write_text(adapted)

# 11. Database. The demo's database.yml names PostgreSQL (and PGlite for ruby.wasm). This build
#     keeps its local data in SQLite, the store the compiled runtime can carry into wasm.
open(os.path.join(app, "config/database.yml"), "w").write('''default: &default
  adapter: sqlite3
  database: storage/development.sqlite3

development:
  <<: *default

production:
  <<: *default
''')

# 12. Controllers: this is the browser build, so `browser_only do ... end` is unwrapped to its body
#     (skip_forgery_protection) and `server_only do ... end` is removed, as in the models.
for folder, _dirs, names in os.walk(os.path.join(app, "app/controllers")):
    for name in names:
        if not name.endswith(".rb"):
            continue
        target = os.path.join(folder, name)
        source = open(target).read()
        changed = re.sub(r"\n( *)server_only do\n.*?\n\1end\n", "\n", source, flags=re.S)

        def unwrap(match):
            indent = match.group(1)
            body = [line[2:] if line.startswith(indent + "  ") else line for line in match.group(2).split("\n")]
            return "\n" + "\n".join(body) + "\n"

        changed = re.sub(r"\n( *)browser_only do\n(.*?)\n\1end\n", unwrap, changed, flags=re.S)
        if changed != source:
            open(target, "w").write(changed)

# 14. The compiled models give a new record an empty-string id, not nil, so the gem's
#     `self.id ||= SecureRandom.uuid` never assigns. Same meaning in Rails, spelled for both.
edit("app/models/concerns/syncable.rb", "self.id ||= SecureRandom.uuid", "self.id = SecureRandom.uuid if id.blank?")

if not os.environ.get("INSTANT_RECORD_APP"):
    # The demo's :app stylesheet tag expands these files during translation.
    # Give each URL a content hash so returning tabs pick up responsive fixes.
    for sheet in Path(app, "app/assets/stylesheets").glob("*.css"):
        digest = hashlib.sha256(sheet.read_bytes()).hexdigest()[:10]
        sheet.rename(sheet.with_name(f"{sheet.stem}-{digest}.css"))
    # The source drawer loads generated source fragments for this build.
    target = os.path.join(app, "app/views/layouts/application.html.erb")
    source = open(target).read()
    source = source.replace('<span class="micro-label">Local-first Rails demos —',
                            '<span class="micro-label"><a href="/">All demos</a> ·')
    source = source.replace('<%= source_path(page: controller_path, view: action_name) %>', "/source")
    source = source.replace("Read live out of app.wasm — not a snippet", "View the source for this build")
    source = (source.replace("Rails on ruby.wasm", "Compiled Rails")
              .replace("This browser · service worker", "This browser · dedicated worker")
              .replace("PGlite — Postgres in this tab", "SQLite in this tab")
              .replace("SSE, held open", "polled every second"))
    open(target, "w").write(source)

    # The receipt ledger describes the phases the dedicated worker actually measures.
    receipt_view = os.path.join(app, "app/views/receipts/index.html.erb")
    with open(receipt_view) as f:
        receipts = f.read()
    for before, after in [
        ("CRuby, Rails, the gems and this app", "The Spinel runtime, Rails and this app"),
        ("CRuby compiled", "WebAssembly compiled"),
        ("PGlite — a Postgres in wasm, kept in IndexedDB", "Local SQLite file read from IndexedDB"),
        ("Schema prepared", "Bootstrap"),
        ("your migrations, against the local Postgres", "initial sync when the tab has no saved database"),
        ("by the service worker as it booted", "by the dedicated worker as it booted"),
    ]:
        receipts = receipts.replace(before, after)
    start = receipts.index("        <strong>Repeatable.</strong>")
    end = receipts.index("      </li>", start)
    receipts = receipts[:start] + """        <strong>Repeatable.</strong> Clearing this tab’s local SQLite database discards
        pending writes after confirmation. The next load requests a fresh copy of the
        compiled module and measures the download and bootstrap again.
""" + receipts[end:]
    with open(receipt_view, "w") as f:
        f.write(receipts)

    # Roundhouse layouts have no controller_path. Each full view supplies its
    # scope just as it supplies its title, so styles stay confined to that demo.
    target = Path(app, "app/views/layouts/application.html.erb")
    source = target.read_text().replace('demo-<%= controller_path.split("/").first %>', 'demo-<%= content_for(:demo_scope) %>')
    target.write_text(source)
    for view in Path(app, "app/views").rglob("*.html.erb"):
        if view.name.startswith("_") or view.parent.name == "layouts":
            continue
        scope = view.relative_to(Path(app, "app/views")).parts[0]
        view.write_text(f'<% content_for(:demo_scope, "{scope}") %>\n' + view.read_text())

    # The reset goes to the authoritative Rails server through the host's network marker.
    edit("app/helpers/slack_helper.rb", "InstantRecord.server_url(slack_reset_path)", '"/slack/reset?instant_record_network=1"')

    # 16. One instance variable holds a relation in one branch and [] in the other; the compiled
    #     code needs a single type, so the relation is loaded (same rows, same order).
    edit("app/controllers/slack/channels_controller.rb",
         "@thread_parent.replies.includes(:chat_user).order(:created_at, :id) : []",
         "@thread_parent.replies.includes(:chat_user).order(:created_at, :id).to_a : []")

print("vendored", len(COPY) + 1, "gem files; client.rb, syncable.rb, outbox_mutation.rb, sync_metadata.rb, sync_window.rb, change.rb are unmodified")
