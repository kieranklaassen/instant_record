#!/usr/bin/env python3
"""Build the compiled browser app: demo source -> seams -> Roundhouse -> Spinel -> wasm -> web/dist.

usage: build.py            (run from anywhere; everything lands in <repo>/.build and <repo>/web/dist)

Toolchains and the gem checkout live outside this repo; toolchain.env names them.
The knobs an optimization is most likely to turn are the constants right below.
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from source_pages import write_source_pages

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_ROOT = os.path.dirname(ROOT)
APP_SOURCE = os.environ.get("INSTANT_RECORD_APP")

# ── build knobs ──────────────────────────────────────────────────────────────
SPINEL_FLAGS = []  # extra flags for `spinel --target=wasm32-wasi`
WASM_OPT_LEVEL = "-Oz"
WASM_OPT_PASS = "-Oz"  # binaryen wasm-opt pass (skipped if wasm-opt is not on PATH)
SQLITE_CFLAGS = [
    "-Oz", "-DSQLITE_THREADSAFE=0", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_OMIT_SHARED_CACHE", "-DSQLITE_OMIT_WAL",
    "-DSQLITE_MAX_MMAP_SIZE=0", "-DSQLITE_DEFAULT_SYNCHRONOUS=0", "-DSQLITE_OMIT_DEPRECATED",
    "-DSQLITE_OMIT_PROGRESS_CALLBACK", "-DSQLITE_TEMP_STORE=2",
    "-DSQLITE_OMIT_UTF16", "-DSQLITE_OMIT_AUTHORIZATION", "-DSQLITE_OMIT_COMPLETE",
    "-DSQLITE_OMIT_TRACE", "-DSQLITE_OMIT_TCL_VARIABLE", "-DSQLITE_OMIT_COMPILEOPTION_DIAGS",
    "-DSQLITE_OMIT_AUTOVACUUM", "-DSQLITE_OMIT_BLOB_LITERAL",
]
STRIP = True  # llvm-strip the module (names and debug sections)
SYNC_ENDPOINT = os.environ.get("SYNC_ENDPOINT", "http://127.0.0.1:3210/instant_record").rstrip("/")
SHELL_FORMAT = 1
REACTOR_EXPORTS = "WasmBridge.handle_request,WasmBridge.handle_sync,WasmBridge.sync_plan,WasmBridge.handle_stream,WasmBridge.cursor,WasmBridge.history"
# ─────────────────────────────────────────────────────────────────────────────


def toolchain():
    values = {}
    for line in open(os.environ.get("INSTANT_RECORD_TOOLCHAIN", os.path.join(ROOT, "toolchain.env"))):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        for known, replacement in values.items():
            value = value.replace("$" + known, replacement)
        values[key] = value
    return values


T = toolchain()
GEM_SRC = os.environ.get("GEM_SRC") or REPO_ROOT
B = os.path.join(ROOT, ".build")
WASI_CFLAGS = [
    "--target=wasm32-wasip1",
    "-ffunction-sections",
    "-fdata-sections",
    "-D_WASI_EMULATED_MMAN",
    "-D_WASI_EMULATED_SIGNAL",
    "-D_WASI_EMULATED_PROCESS_CLOCKS",
    "-D_WASI_EMULATED_GETPID",
]
WASM_OPT_FEATURES = [
    "--enable-exception-handling",
    "--enable-bulk-memory",
    "--enable-nontrapping-float-to-int",
    "--enable-sign-ext",
    "--enable-mutable-globals",
    "--enable-reference-types",
]


def run(args, cwd=None, env=None, log=None):
    merged = dict(os.environ)
    merged.update(env or {})
    result = subprocess.run(args, cwd=cwd, env=merged, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if log:
        open(os.path.join(B, log), "w").write(result.stdout)
    if result.returncode != 0:
        tail = "\n".join(line for line in result.stdout.splitlines() if "--rbs" not in line and "warning:" not in line)[-1500:]
        raise SystemExit(f"build step failed: {' '.join(args[:3])}\n{tail}")
    return result.stdout


def clean(path):
    assert path.startswith(B + os.sep), path  # only ever inside .build
    shutil.rmtree(path, ignore_errors=True)


def sqlite_library():
    """libsqlite3.a for wasm32-wasi: the amalgamation plus the 32-bit shim, cached by flags."""
    shim = os.path.join(ROOT, "pipeline/sqlite/rh_shim.c")
    key = hashlib.sha256((" ".join(SQLITE_CFLAGS) + open(shim).read()).encode()).hexdigest()[:16]
    out = os.path.join(T["CACHE"], "sqlite-" + key)
    if not os.path.exists(os.path.join(out, "libsqlite3.a")):
        os.makedirs(out, exist_ok=True)
        clang = os.path.join(T["WASI_SDK"], "bin/clang")
        run([clang, *WASI_CFLAGS, *SQLITE_CFLAGS, "-c", os.path.join(T["SQLITE_SRC"], "sqlite3.c"), "-o", os.path.join(out, "sqlite3.o")])
        run([clang, *WASI_CFLAGS, WASM_OPT_LEVEL, "-I" + T["SQLITE_SRC"], "-c", shim, "-o", os.path.join(out, "rh_shim.o")])
        run([os.path.join(T["WASI_SDK"], "bin/llvm-ar"), "rcs", os.path.join(out, "libsqlite3.a"), os.path.join(out, "sqlite3.o"), os.path.join(out, "rh_shim.o")])
    return out


def input_digest():
    """Everything a build depends on inside this checkout, so an unchanged checkout is not rebuilt."""
    digest = hashlib.sha256()
    paths = [os.environ.get("INSTANT_RECORD_TOOLCHAIN", os.path.join(ROOT, "toolchain.env")), os.path.join(ROOT, "web/index.html"), os.path.join(ROOT, "web/vite.config.js")]
    paths.extend(os.path.join(ROOT, "web", name) for name in ("package.json", "package-lock.json"))
    paths.append(os.path.join(GEM_SRC, "lib/instant_record.rb"))
    inputs = [(ROOT, ["pipeline", "web/src"]), (GEM_SRC, ["lib/instant_record", "app/models/instant_record"])]
    app_source = APP_SOURCE or os.path.join(GEM_SRC, "demo")
    inputs.append((app_source, ["app", "config/routes", "config/locales"]))
    if APP_SOURCE:
        inputs.append((app_source, ["db/browser_migrate"]))
        for directory in json.loads(os.environ.get("INSTANT_RECORD_MIGRATION_PATHS", "null")) or [os.path.join(app_source, "db/migrate")]:
            inputs.append((directory, ["."]))
        digest.update(os.environ.get("INSTANT_RECORD_MIGRATION_BASELINE", "").encode())
    for name in ("config/routes.rb", "config/application.rb", "config/importmap.rb", "db/schema.rb", "Gemfile"):
        if os.path.isfile(os.path.join(app_source, name)):
            paths.append(os.path.join(app_source, name))
    digest.update(os.environ.get("INSTANT_RECORD_MODELS", "").encode())
    digest.update(os.environ.get("INSTANT_RECORD_SHELL_SNAPSHOT", "").encode())
    for base_root, folders in inputs:
        for folder in folders:
            full = os.path.join(base_root, folder)
            if not os.path.isdir(full):
                continue
            for base, _dirs, names in os.walk(full):
                paths += [os.path.join(base, name) for name in names if not name.endswith(".pyc")]
    for path in sorted(set(paths)):
        digest.update(os.path.relpath(path, REPO_ROOT).encode())
        digest.update(open(path, "rb").read())
    digest.update(SYNC_ENDPOINT.encode())
    return digest.hexdigest()


def compile_reactor(tree, flags, sqlite, path_env):
    """Emit C library via Spinel (--ext-init/--ext-entry) and link as a WASI reactor."""
    build_dir = os.path.join(tree, "build")
    os.makedirs(build_dir, exist_ok=True)
    app_c = os.path.join(build_dir, "app.c")
    wasm = os.path.join(build_dir, "app.wasm")
    shim_c = os.path.join(ROOT, "pipeline/reactor_shim.c")

    run([
        "spinel", "--target=wasm32-wasi", "-c",
        "--ext-init", "app_boot",
        "--ext-entry", REACTOR_EXPORTS,
        *flags, *SPINEL_FLAGS,
        "main_wasm.rb", "-o", app_c,
    ], cwd=tree, env={**path_env, "CPATH": T["SQLITE_SRC"]}, log="spinel.log")

    spinel_home = T["SPINEL_HOME"]
    clang = os.path.join(T["WASI_SDK"], "bin/clang")
    pkg_objs = [
        os.path.join(spinel_home, "packages/json/sp_json_wasi.o"),
        os.path.join(spinel_home, "packages/stringio/sp_stringio_wasi.o"),
        os.path.join(spinel_home, "packages/zlib/sp_zlib_wasi.o"),
    ]
    run([
        clang, *WASI_CFLAGS, "-mexec-model=reactor", WASM_OPT_LEVEL,
        "-Wno-all", "-ffunction-sections", "-fdata-sections", "-ffp-contract=off",
        "-DSP_INT_OVERFLOW_MODE_RAISE",
        "-I" + os.path.join(spinel_home, "lib"),
        "-I" + os.path.join(spinel_home, "lib/regexp"),
        "-I" + os.path.join(spinel_home, "lib/wasi"),
        "-I" + T["SQLITE_SRC"],
        "-I" + build_dir,
        "-mllvm", "-wasm-enable-sjlj",
        "-mllvm", "-wasm-use-legacy-eh=false",
        app_c, shim_c,
        *pkg_objs,
        os.path.join(spinel_home, "lib/wasm32-wasi/libspinel_rt.a"),
        "-L" + sqlite, "-lsqlite3",
        "-lm", "-lsetjmp",
        "-lwasi-emulated-signal", "-lwasi-emulated-process-clocks",
        "-lwasi-emulated-getpid", "-lwasi-emulated-mman",
        "-Wl,-z,stack-size=8388608", "-Wl,--gc-sections",
        "-o", wasm,
    ], cwd=tree, env=path_env, log="clang.log")
    return wasm


def optimize_wasm(tree, wasm):
    """Strip debug/name sections and run binaryen wasm-opt when installed."""
    final = wasm
    if STRIP:
        stripped = os.path.join(tree, "build/app.stripped.wasm")
        run([os.path.join(T["WASI_SDK"], "bin/llvm-strip"), "-o", stripped, final])
        final = stripped
    wasm_opt = shutil.which("wasm-opt")
    if wasm_opt and WASM_OPT_PASS:
        opted = os.path.join(tree, "build/app.opt.wasm")
        run([wasm_opt, WASM_OPT_PASS, *WASM_OPT_FEATURES, final, "-o", opted], cwd=tree, log="wasm-opt.log")
        final = opted
    return final


def outside_stylesheets(app):
    """The stylesheets a layout takes from another site (its web fonts), asked for while wasm
    compiles.

    The page the app writes names them only once the app is up, and a stylesheet holds the
    paint until it has arrived: a round trip to another site, after everything else is ready.
    Preloaded from the shell, the answer is in the HTTP cache when the page asks.
    """
    layouts = os.path.join(app, "app/views/layouts")
    links = []
    if not os.path.isdir(layouts):
        return links
    for name in sorted(os.listdir(layouts)):
        for tag in re.findall(r"<link\b[^>]*>", open(os.path.join(layouts, name)).read()):
            href = re.search(r'href="(https://[^"<]+)"', tag)
            if not href:
                continue
            if 'rel="preconnect"' in tag and "    " + tag not in links:
                links.append("    " + tag)  # where its fonts come from: the layout knows
            if 'rel="stylesheet"' in tag and "crossorigin" not in tag:
                links.append(f'    <link rel="preload" as="style" href="{href.group(1)}">')
    return links


CORE_PRELOAD_STYLES = ("base", "ui", "mail")


def inject_preloads(dist, app=None):
    """Preload outside font stylesheets, worker bundle, and core CSS without starving /app-*.wasm.

    Chrome's HTTP/1.1 connection pool has 6 sockets per origin. Preloading all 11 demo stylesheets
    as Highest-priority <link rel="preload" as="style"> saturates all 6 sockets for 2 RTT waves
    (~127 ms) before /app-*.wasm starts downloading. Keeping at most 3 core stylesheets (base, ui,
    mail — which carries the one-paint visibility rule) as fetchpriority="low" preloads leaves 3
    Wave-1 sockets free for index.js, worker.js, and app.wasm, while warming the remaining demo
    stylesheets via low-priority fetch() in warm_scripts.
    """
    links = outside_stylesheets(app) if app else []
    harness_dir = os.path.join(dist, "harness")
    if os.path.isdir(harness_dir):
        for name in sorted(os.listdir(harness_dir)):
            if name.startswith("worker-") and name.endswith(".js"):
                links.append(f'    <link rel="modulepreload" fetchpriority="high" href="/harness/{name}">')
    assets_dir = os.path.join(dist, "assets")
    deferred_css = []
    if os.path.isdir(assets_dir):
        css_files = [name for name in sorted(os.listdir(assets_dir)) if name.endswith(".css")]
        for name in css_files:
            stem = name.rsplit("-", 1)[0] if "-" in name else name[:-4]
            if len(css_files) <= 3 or stem in CORE_PRELOAD_STYLES:
                links.append(f'    <link rel="preload" as="style" fetchpriority="low" href="/assets/{name}">')
            else:
                deferred_css.append(name)
    links += warm_scripts(assets_dir, deferred_css)
    if not links:
        return
    index_path = os.path.join(dist, "index.html")
    html = open(index_path).read()
    open(index_path, "w").write(html.replace("  </head>", "\n".join(links) + "\n  </head>", 1))


def warm_scripts(assets_dir, deferred_css=()):
    """The app's scripts (and non-core stylesheets), fetched at low priority while wasm compiles.

    The page the app writes names its scripts only once the app is up, and they import one
    another several levels deep: a round trip a level, all of it after the boot. A plain fetch
    parses nothing and resolves no specifier. It only has the response cached, under the
    address the page will ask for: a controller's carries the version emit_tree gave it, and
    the Inbox's bundle the one vendor_gem.py wrote into its view.
    """
    urls = []
    seen = hashlib.sha256()
    for name in deferred_css:
        path = os.path.join(assets_dir, name)
        if not os.path.isfile(path):
            continue
        with open(path, "rb") as f:
            digest = hashlib.sha256(f.read()).hexdigest()[:10]
        seen.update((name + digest).encode())
        urls.append("/assets/" + name)
    for folder, prefix in ((assets_dir, "/assets/"), (os.path.join(assets_dir, "controllers"), "/assets/controllers/")):
        if not os.path.isdir(folder):
            continue
        for name in sorted(os.listdir(folder)):
            path = os.path.join(folder, name)
            if not name.endswith(".js") or not os.path.isfile(path):
                continue
            with open(path, "rb") as f:
                digest = hashlib.sha256(f.read()).hexdigest()[:10]
            seen.update((name + digest).encode())
            versioned = prefix.endswith("controllers/") or (name == "inbox.js" and not APP_SOURCE)
            urls.append(prefix + name + ("?v=" + digest if versioned else ""))
    if not urls:
        return []
    # Once a browser, for these assets: on a later visit they are cached already, and asking
    # again only takes time from the boot (50 ms of a 220 ms return visit, measured).
    return ["    <script>try { if (localStorage.getItem(\"instant_record.warmed\") !== \"" + seen.hexdigest()[:12] + "\") {"
            " localStorage.setItem(\"instant_record.warmed\", \"" + seen.hexdigest()[:12] + "\");"
            " for (const url of " + json.dumps(urls) + ") fetch(url, { priority: \"low\" }).catch(function () {}); } } catch (error) {}</script>"]


def emit_tree(python):
    """Steps 1 to 3, which the native build (build_native.py) shares: the staged app, the Spinel
    project Roundhouse emits from it, and the single-threaded copy with its reactor entry."""
    # 1. Stage the Rails app and adapt the gem's sync client to the browser host.
    app = os.path.join(B, "app-src")
    if APP_SOURCE:
        plan_path = os.path.join(B, "browser-migrations.json")
        run(["ruby", os.path.join(ROOT, "pipeline/browser_migrations.rb"), APP_SOURCE, plan_path])
        with open(plan_path) as file:
            plan = json.load(file)
        run([python, os.path.join(ROOT, "pipeline/prepare_app.py"), APP_SOURCE, app])
    else:
        plan = {"version": 1, "baseline": 0, "migrations": {}, "history": {"1": "add-mail-tables"}}
        run([python, os.path.join(ROOT, "pipeline/carve.py"), GEM_SRC, app])
    run([python, os.path.join(ROOT, "pipeline/vendor_gem.py"), GEM_SRC, app])

    # 2. Roundhouse: Rails app -> Spinel project.
    emit = os.path.join(B, "emit")
    clean(emit)
    run([T["ROUNDHOUSE_BIN"], "--target", "spinel", "-o", emit, app], log="emit.log")
    # Roundhouse emits plain controller URLs. Version them so reloads pick up matching protocols.
    controller_dir = os.path.join(app, "app/javascript/controllers")
    for config in ("config/importmap.rb", "config/application.rb"):
        path = os.path.join(emit, config)
        if not os.path.isfile(path) or not os.path.isdir(controller_dir):
            continue
        with open(path) as f:
            source = f.read()
        for name in os.listdir(controller_dir):
            if not name.endswith(".js") or not os.path.isfile(os.path.join(controller_dir, name)):
                continue
            with open(os.path.join(controller_dir, name), "rb") as f:
                version = hashlib.sha256(f.read()).hexdigest()[:10]
            asset = "/assets/controllers/" + name
            source = source.replace(asset, asset + "?v=" + version)
        with open(path, "w") as f:
            f.write(source)
    toml = os.path.join(emit, "spin.toml")
    with open(toml) as f:
        spin_config = f.read()
    open(toml, "w").write(spin_config.replace('\nallocator = "jemalloc"', '\n# allocator = "jemalloc"  (wasm build: no jemalloc)'))

    # 3. Persistent reactor entry and the single-threaded copy for wasm32-wasi.
    tree = os.path.join(B, "wasm-tree")
    clean(tree)
    run([python, os.path.join(ROOT, "pipeline/make_wasm_entry.py"), emit], env={
        "INSTANT_RECORD_MIGRATION_PLAN": os.path.join(B, "browser-migrations.json") if APP_SOURCE else ""})
    run([python, os.path.join(ROOT, "pipeline/make_wasm_tree.py"), emit, tree])
    return app, emit, tree, plan


def main():
    os.makedirs(B, exist_ok=True)
    os.makedirs(T["CACHE"], exist_ok=True)
    stamp = os.path.join(B, "stamp")
    wanted = input_digest()
    if os.path.exists(stamp) and open(stamp).read() == wanted and os.path.exists(os.path.join(ROOT, "web/dist/index.html")):
        print("build is current")
        return
    if os.path.exists(stamp):
        os.unlink(stamp)
    python = sys.executable
    path_env = {"PATH": os.path.join(T["SPINEL_HOME"], "bin") + os.pathsep + os.environ["PATH"], "WASI_SDK": T["WASI_SDK"]}

    app, emit, tree, plan = emit_tree(python)

    # 4. Spinel: Ruby -> C -> WASI reactor wasm, with SQLite linked in.
    sqlite = sqlite_library()
    flags = run(["spin", "flags"], cwd=tree, env=path_env).split()
    wasm = compile_reactor(tree, flags, sqlite, path_env)
    final = optimize_wasm(tree, wasm)

    # 5. The host harness and the demo's own assets, laid out as a static site.
    web = os.path.join(ROOT, "web")
    modules = os.path.join(web, "node_modules")
    if not os.path.exists(modules):
        os.symlink(T["WEB_NODE_MODULES"], modules)
    digest = hashlib.sha256(open(final, "rb").read()).hexdigest()[:10]
    output = os.path.join(web, "dist")
    dist = os.path.join(B, "site")
    # What a server-built shell database has to match before the worker opens one as its own:
    # the app's schema and the model list this build saves in its sync metadata. The demo's
    # MailShell.fingerprint computes the same digest, and SHELL_FORMAT is its FORMAT.
    model_set = re.search(r'model_set = "([^"]*)"', open(os.path.join(emit, "main_wasm.rb")).read()).group(1)
    schema_source = open(os.path.join(app, "db/schema.rb")).read()
    shell_fingerprint = hashlib.sha256("\n".join([str(SHELL_FORMAT), model_set, schema_source]).encode()).hexdigest()
    run(["npx", "vite", "build", "--outDir", dist, "--emptyOutDir"], cwd=web, env={"VITE_WASM_URL": f"/app-{digest}.wasm",
        "VITE_SHELL_FINGERPRINT": shell_fingerprint,
        "VITE_SHELL_SNAPSHOT": os.environ.get("INSTANT_RECORD_SHELL_SNAPSHOT", ""),
        "VITE_SHARED_INBOX_DEMO": "" if APP_SOURCE else "1",
        "VITE_SYNC_ENDPOINT": SYNC_ENDPOINT, "VITE_SOURCE_VERSION": wanted[:12],
        "VITE_SCHEMA_VERSION": str(plan["version"]),
        "VITE_SCHEMA_BASELINE": "" if plan["baseline"] is None else str(plan["baseline"]),
        "VITE_MIGRATION_HISTORY": json.dumps(plan.get("history", {})),
        "VITE_SCHEMA_DIGEST": hashlib.sha256(open(os.path.join(emit, "config/schema.rb"), "rb").read()).hexdigest()}, log="vite.log")
    with open(os.path.join(dist, "instant-record-release.json"), "w") as release:
        json.dump({"version": wanted}, release)
    shutil.copy(final, os.path.join(dist, f"app-{digest}.wasm"))
    assets = os.path.join(dist, "assets")
    os.makedirs(os.path.join(assets, "controllers"), exist_ok=True)
    # The Rails helpers can emit logical URLs such as /assets/icon.svg even
    # when Roundhouse doesn't generate a digested static asset directory.
    # app/assets/builds holds the Inbox's React bundle (`npm run build` in the app).
    for asset_dir in (os.path.join(app, "app/assets/stylesheets"), os.path.join(app, "app/assets/images"),
                      os.path.join(app, "app/assets/builds"),
                      os.path.join(emit, "static/assets"), os.path.join(app, "app/javascript")):
        if os.path.isdir(asset_dir):
            shutil.copytree(asset_dir, assets, dirs_exist_ok=True)
    for name in ["turbo.min.js", "stimulus.min.js", "stimulus-loading.js"]:
        found = subprocess.run(["find", T["RAILS_GEMS"], "-name", name], stdout=subprocess.PIPE, text=True).stdout.split("\n")[0]
        if found:
            shutil.copy(found, assets)
    if not APP_SOURCE:
        write_source_pages(app, dist, wanted[:12], os.path.join(GEM_SRC, "demo"))
    # The service worker that keeps the shell: the same file Rails serves at /service-worker.js.
    # Read from the app's own checkout: the demo's staged copy leaves app/views/pwa out.
    shell_worker = os.path.join(APP_SOURCE or os.path.join(GEM_SRC, "demo"), "app/views/pwa/service-worker.js")
    if os.path.isfile(shell_worker):
        shutil.copy(shell_worker, os.path.join(dist, "service-worker.js"))
    inject_preloads(dist, APP_SOURCE or os.path.join(GEM_SRC, "demo"))
    previous = os.path.join(B, "previous-site")
    clean(previous)
    if os.path.isdir(output):
        os.replace(output, previous)
    try:
        os.replace(dist, output)
    except OSError:
        if os.path.isdir(previous):
            os.replace(previous, output)
        raise
    clean(previous)
    print(f"built web/dist with app-{digest}.wasm ({os.path.getsize(final)} bytes)")
    open(stamp, "w").write(wanted)


if __name__ == "__main__":
    main()
