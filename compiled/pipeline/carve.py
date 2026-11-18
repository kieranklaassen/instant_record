#!/usr/bin/env python3
"""Prepare all demo pages for the compiled browser runtime.

usage: carve.py <instant_record checkout> <target app dir>

The source seams (what has to differ from the original for the compiled build) are applied
afterwards by vendor_gem.py; this step only removes what is not carried.
"""
import os
import shutil
import sys

gem, app = sys.argv[1], sys.argv[2]
demo = os.path.join(gem, "demo")

shutil.rmtree(app, ignore_errors=True)
shutil.copytree(demo, app, ignore=shutil.ignore_patterns("log", "tmp", "pwa", "node_modules", "storage", ".bundle"))

# Source drawers are static build artifacts. Slack reset runs on the sync server.
REMOVE = [
    # Browser dependencies come from the compiled runtime. The server's lockfile
    # would also bring Rack's request throttling middleware into the Wasm build.
    "Gemfile.lock", "config/initializers/rack_attack.rb",
    # The compiled worker gets its endpoint from SYNC_ENDPOINT.
    "config/initializers/instant_record.rb",
    "app/controllers/source_controller.rb",
    "app/controllers/slack/resets_controller.rb", "app/controllers/email/sync_controller.rb", "app/models/mailbox.rb",
    "app/views/source", "app/views/pwa",
    "app/helpers/source_helper.rb",
    "test", "db/v2_migrate", "db/seeds.rb", "config/routes", "script", "lib/tasks",
]
for rel in REMOVE:
    path = os.path.join(app, rel)
    if os.path.isdir(path):
        shutil.rmtree(path)
    elif os.path.exists(path):
        os.unlink(path)

open(os.path.join(app, "config/routes.rb"), "w").write('''Rails.application.routes.draw do
  namespace :todo do
    resources :issues, only: [:create, :update, :destroy]
    root "issues#index" # /todo
  end

  namespace :slack do
    resources :channels, only: [:show]
    resources :messages, only: [:create]
    root "channels#index" # /slack
  end

  namespace :migrate do
    root "notes#index"
    resources :notes, only: [:create]
    post "ship", to: "releases#create"
    delete "ship", to: "releases#destroy"
  end
  get "email", to: "email/mailboxes#index"
  post "email", to: "email/mailboxes#create"
  namespace :console do
    root "sessions#index"
  end
  get "receipts", to: "receipts#index", as: :receipts
  get "receipts/probe", to: "receipts#probe", as: :receipts_probe
  get "home", to: "home#index"
  root "home#index"
end
''')

# Views and model seams specific to the SQLite reactor.
overlay = os.path.join(os.path.dirname(__file__), "demo")
shutil.copytree(overlay, os.path.join(app, "app"), dirs_exist_ok=True)

# Use the demo's own templates, with SQLite metadata and worker-routed form visits.
migration_view = os.path.join(app, "app/views/migrate/notes/index.html.erb")
with open(migration_view) as f:
    migration = f.read().replace("local Postgres", "local SQLite database").replace("turbo: false", "turbo: true")
# Adapt the Rails migration view to the compiled SQLite implementation.
migration = migration.replace("<% has_word_count = @columns.include?(Release::COLUMN) %>", "")
migration = migration.replace("<% if has_word_count %>", "<% unless @release_pending %>")
migration = migration.replace("a\n        migration-local model with <code>update_columns</code>, so nothing\n        queues", "a direct SQLite update in the same transaction")
migration = migration.replace("The\n          migration is an <code>add_column</code> inside <code>change</code>, so\n          this is its real reversal — not a separate undo written by hand.", "Rollback uses <code>ALTER TABLE</code> and removes the local migration version.")
with open(migration_view, "w") as f:
    f.write(migration)

# Slack::Seeds: the browser-side controller reads its constants; the seeding routines are
# server-only (and use find_or_create_by blocks the compiler refuses).
seeds = os.path.join(app, "app/models/slack/seeds.rb")
source = open(seeds).read()
cut = source.index("    module_function")
open(seeds, "w").write(source[:cut] + "    # Browser build: the seeding routines (apply, backfill) are server-only and left out;\n"
                       "    # the constants above are what the browser-side controller reads.\n  end\nend\n")

# The server appends under a locked mailbox. The local model writes to the
# ordinary InstantRecord outbox and the worker sends it to the selected inbox.
letter = os.path.join(app, "app/models/mail_entry.rb")
source = open(letter).read().replace("class MailEntry < ApplicationRecord", "class MailEntry < ApplicationRecord\n  include InstantRecord::Syncable")
open(letter, "w").write(source)
