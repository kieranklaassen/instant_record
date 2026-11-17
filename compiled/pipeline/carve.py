#!/usr/bin/env python3
"""Copy the gem's demo app and keep only the Todo and Slack demos, unmodified.

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

# The other four demos (console, migrate, receipts, source), the home page, the server-only
# reset endpoint, tests and build tooling are not part of this build.
REMOVE = [
    "app/controllers/console", "app/controllers/migrate", "app/controllers/receipts_controller.rb",
    "app/controllers/source_controller.rb", "app/controllers/home_controller.rb",
    "app/controllers/slack/resets_controller.rb",
    "app/views/console", "app/views/migrate", "app/views/receipts", "app/views/source", "app/views/home", "app/views/pwa",
    "app/models/note.rb", "app/models/release.rb", "app/helpers/source_helper.rb",
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

  root "todo/issues#index"
end
''')

# Slack::Seeds: the browser-side controller reads its constants; the seeding routines are
# server-only (and use find_or_create_by blocks the compiler refuses).
seeds = os.path.join(app, "app/models/slack/seeds.rb")
source = open(seeds).read()
cut = source.index("    module_function")
open(seeds, "w").write(source[:cut] + "    # Browser build: the seeding routines (apply, backfill) are server-only and left out;\n"
                       "    # the constants above are what the browser-side controller reads.\n  end\nend\n")
