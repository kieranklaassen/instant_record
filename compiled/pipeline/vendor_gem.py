#!/usr/bin/env python3
"""Vendor the instant_record gem's own Ruby into the carved app's lib/, then apply the host seams.

Everything not listed under SEAMS is the gem's file, byte for byte. The seams are the places
where the gem talks to ruby.wasm's JavaScript bridge or leans on runtime metaprogramming.
"""
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

# 7. Instrumentation forwards ActiveSupport::Notifications to a JS function for the demo's sync
#    inspector, which this build does not carry.
open(os.path.join(app, "lib/instant_record/client/instrumentation.rb"), "w").write('''module InstantRecord
  module Client
    # Host seam (see vendor_gem.py): the inspector feed is not carried.
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
for model in ["issue", "channel", "chat_user", "message"]:
    target = os.path.join(app, f"app/models/{model}.rb")
    source = open(target).read().replace("include InstantRecord::Syncable", "include Syncable")
    open(target, "w").write(source)

# 9. `server_only do ... end` blocks in models hold code the browser never runs (the gem skips them
#    at runtime). Ahead of time they have to go before the compiler sees them.
import re
for name in os.listdir(os.path.join(app, "app/models")):
    if not name.endswith(".rb"):
        continue
    target = os.path.join(app, "app/models", name)
    source = open(target).read()
    stripped = re.sub(r"\n( *)server_only do\n.*?\n\1end\n", "\n", source, flags=re.S)
    if stripped != source:
        open(target, "w").write(stripped)

# 10. The layout's "code behind this page" drawer belongs to the source demo, which is not carried.
target = os.path.join(app, "app/views/layouts/application.html.erb")
source = open(target).read()
if "source-drawer" in source:
    a = source.index("    <%# Proof rather than prose")
    b = source.index("    </details>\n", a) + len("    </details>\n")
    open(target, "w").write(source[:a] + source[b:])

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

# 13. The layout reads controller_path for a per-demo body class; the compiled layout runtime has
#     no controller_path, so both demo style scopes are named outright.
target = os.path.join(app, "app/views/layouts/application.html.erb")
source = open(target).read()
open(target, "w").write(source.replace('demo-<%= controller_path.split("/").first %>', "demo-todo demo-slack"))

# 15. The Slack sidebar's "Reset demo" form posts to a server-only endpoint that is not carried.
target = os.path.join(app, "app/views/slack/channels/_sidebar.html.erb")
source = open(target).read()
if "reset-form" in source:
    a = source.index("    <%# Posted by the reset controller")
    b = source.index("    </form>\n", a) + len("    </form>\n")
    open(target, "w").write(source[:a] + source[b:])
helper = os.path.join(app, "app/helpers/slack_helper.rb")
source = open(helper).read()
if "  def slack_reset_endpoint" in source:
    a = source.index("  def slack_reset_endpoint")
    b = source.index("  end\n", a) + len("  end\n")
    open(helper, "w").write(source[:a] + source[b:].lstrip("\n"))

# 16. One instance variable holds a relation in one branch and [] in the other; the compiled
#     code needs a single type, so the relation is loaded (same rows, same order).
edit("app/controllers/slack/channels_controller.rb",
     "@thread_parent.replies.includes(:chat_user).order(:created_at, :id) : []",
     "@thread_parent.replies.includes(:chat_user).order(:created_at, :id).to_a : []")

# 14. The compiled models give a new record an empty-string id, not nil, so the gem's
#     `self.id ||= SecureRandom.uuid` never assigns. Same meaning in Rails, spelled for both.
edit("app/models/concerns/syncable.rb", "self.id ||= SecureRandom.uuid", "self.id = SecureRandom.uuid if id.blank?")

print("vendored", len(COPY) + 1, "gem files; client.rb, syncable.rb, outbox_mutation.rb, sync_metadata.rb, sync_window.rb, change.rb are unmodified")
