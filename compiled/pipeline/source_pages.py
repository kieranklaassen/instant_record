"""Build lazy source drawers from the same app copy Roundhouse compiled."""
import html
import re
from pathlib import Path

PAGES = {
    "assistant": ("assistant/turns", "index", ("assistant_chat", "assistant_turn")),
    "auth": ("auth/notes", "index", ("auth_note", "auth_person")),
    "home": ("home", "index", ()),
    "email": ("email/mailboxes", "index", ("mail_entry", "mail_directory")),
    "todo": ("todo/issues", "index", ("issue",)),
    "slack": ("slack/channels", "show", ("channel", "chat_user", "message")),
    "migrate": ("migrate/notes", "index", ("note", "release")),
    "console": ("console/sessions", "index", ("issue",)),
    "receipts": ("receipts", "index", ()),
}
MARKER = re.compile(r"InstantRecord[.:]|\b(?:server_only|browser_only|client_only|sync_window|sync_state|pending_count|on_discarded_change)\b")

def write_source_pages(app, dist, version, demo):
    root = Path(app)
    dest = Path(dist, "assets", "source", version)
    dest.mkdir(parents=True, exist_ok=True)
    for key, (controller, action, models) in PAGES.items():
        files = [(f"app/models/{model}.rb", root / f"app/models/{model}.rb") for model in models]
        files.extend((rel, root / rel) for rel in [
            f"app/controllers/{controller}_controller.rb", f"app/views/{controller}/{action}.html.erb"])
        if key in ("assistant", "email"):
            # The Inbox is a React page; the Assistant is a Stimulus controller.
            script = ("app/javascript/controllers/assistant_chat_controller.js" if key == "assistant"
                      else "app/frontend/pages/Email/Inbox.jsx")
            files.append((script, root / script))
        if key == "assistant":
            for part in ("app/views/assistant/turns/_turns.html.erb", "app/javascript/controllers/assistant_local_model.js"):
                files.append((part, root / part))
            # What answers on the server is left out of the build, so it is read from the demo.
            for server in ("app/jobs/assistant/reply_job.rb", "app/models/assistant/reply.rb"):
                files.append((server, Path(demo) / server))
        if key == "auth":
            files.append(("app/javascript/controllers/auth_controller.js", root / "app/javascript/controllers/auth_controller.js"))
            # The session and the rule for who is asking stay on the server, so they are read from the demo.
            for server in ("app/controllers/auth/sessions_controller.rb", "config/initializers/instant_record.rb"):
                files.append((server, Path(demo) / server))
        if key == "migrate":
            files[1] = ("compiled/pipeline/sqlite_release.rb", Path(__file__).with_name("sqlite_release.rb"))
        parts = ['<p class="source-note">Source used by this compiled build. Marked lines use InstantRecord.</p>']
        for label, path in files:
            lines = path.read_text().splitlines()
            marked = sum(bool(MARKER.search(line)) for line in lines)
            parts.append(f'<section class="source-file"><header><span class="source-path">{label}</span>'
                         f'<span class="source-count">{marked} InstantRecord lines of {len(lines)}</span></header><div class="source-code">')
            for index, line in enumerate(lines, 1):
                css = " instant-record" if MARKER.search(line) else ""
                parts.append(f'<div class="source-line{css}"><span class="source-ln">{index}</span>'
                             f'<span class="source-text">{html.escape(line)}</span></div>')
            parts.append('</div></section>')
        (dest / (key + ".html")).write_text("".join(parts))
