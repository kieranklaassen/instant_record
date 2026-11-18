#!/usr/bin/env python3
"""Vendor the instant_record gem's own Ruby into the carved app's lib/, then apply the host seams.

Everything not listed under SEAMS is the gem's file, byte for byte. The seams are the places
where the gem talks to the Rails engine or uses runtime metaprogramming.
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

# The staged source runs exclusively in the browser.
edit("lib/instant_record.rb", "def browser? = false", "def browser? = true")
edit("lib/instant_record.rb", 'require "instant_record/engine" if defined?(Rails::Engine)\n', "")

# 2. Model discovery. ActiveRecord::Base.descendants has no ahead-of-time counterpart; the gem's own
#    explicit allowlist (InstantRecord.sync) takes its place, set in wasm_main.rb.
cut("lib/instant_record.rb", "      ActiveRecord::Base.descendants.select do |model|", "    end\n\n    # One record's attributes as they cross the wire", "      []\n")
edit("lib/instant_record.rb", "      klass = record_type.to_s.safe_constantize\n      klass if klass.respond_to?(:instant_record_syncable?) && klass.instant_record_syncable?\n", "      nil\n")

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

# 11. Database. The demo's database.yml names PostgreSQL. This build
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
    open(target, "w").write(source)

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
