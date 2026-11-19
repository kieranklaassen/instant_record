"""Stage a consumer Rails app for Roundhouse without touching the original checkout."""
import os
import shutil
import sys
from pathlib import Path

source, target = map(Path, sys.argv[1:3])
if target.exists():
    shutil.rmtree(target)
target.mkdir(parents=True)
folders = ["app/controllers", "app/models", "app/views", "app/helpers", "app/assets", "app/javascript",
           "config/routes", "config/locales"]
# Screens are a native app's and are staged for the native build alone, as carve.py does for the demo.
if os.environ.get("INSTANT_RECORD_NATIVE"):
    folders.append("app/screens")
for rel in folders:
    if (source / rel).is_dir():
        shutil.copytree(source / rel, target / rel)
for rel in ("Gemfile", "config/application.rb", "config/routes.rb", "config/importmap.rb", "db/schema.rb"):
    path = source / rel
    if path.is_file():
        (target / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target / rel)
if not (target / "db/schema.rb").is_file():
    sys.exit("The compiled app needs db/schema.rb. Run bin/rails db:migrate and db:schema:dump first.")
