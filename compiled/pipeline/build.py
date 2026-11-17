#!/usr/bin/env python3
"""Build the compiled browser app: demo source -> seams -> Roundhouse -> Spinel -> wasm -> web/dist.

usage: build.py            (run from anywhere; everything lands in <repo>/.build and <repo>/web/dist)

Toolchains and the gem checkout live outside this repo; toolchain.env names them.
The knobs an optimization is most likely to turn are the constants right below.
"""
import hashlib
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ── build knobs ──────────────────────────────────────────────────────────────
SPINEL_FLAGS = []  # extra flags for `spinel --target=wasm32-wasi`
SQLITE_CFLAGS = [
    "-O2", "-DSQLITE_THREADSAFE=0", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_OMIT_SHARED_CACHE", "-DSQLITE_OMIT_WAL",
    "-DSQLITE_MAX_MMAP_SIZE=0", "-DSQLITE_DEFAULT_SYNCHRONOUS=0", "-DSQLITE_OMIT_DEPRECATED",
    "-DSQLITE_OMIT_PROGRESS_CALLBACK", "-DSQLITE_TEMP_STORE=2",
]
STRIP = True  # llvm-strip the module (names and debug sections)
SYNC_ENDPOINT = os.environ.get("SYNC_ENDPOINT", "http://127.0.0.1:3210/instant_record")
# ─────────────────────────────────────────────────────────────────────────────


def toolchain():
    values = {}
    for line in open(os.path.join(ROOT, "toolchain.env")):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        for known, replacement in values.items():
            value = value.replace("$" + known, replacement)
        values[key] = value
    return values


T = toolchain()
B = os.path.join(ROOT, ".build")
WASI_CFLAGS = ["--target=wasm32-wasip1", "-D_WASI_EMULATED_MMAN", "-D_WASI_EMULATED_SIGNAL", "-D_WASI_EMULATED_PROCESS_CLOCKS", "-D_WASI_EMULATED_GETPID"]


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
        run([clang, *WASI_CFLAGS, "-O2", "-I" + T["SQLITE_SRC"], "-c", shim, "-o", os.path.join(out, "rh_shim.o")])
        run([os.path.join(T["WASI_SDK"], "bin/llvm-ar"), "rcs", os.path.join(out, "libsqlite3.a"), os.path.join(out, "sqlite3.o"), os.path.join(out, "rh_shim.o")])
    return out


def input_digest():
    """Everything a build depends on inside this repo, so an unchanged checkout is not rebuilt."""
    digest = hashlib.sha256()
    paths = [os.path.join(ROOT, "toolchain.env"), os.path.join(ROOT, "web/index.html"), os.path.join(ROOT, "web/vite.config.js")]
    for folder in ["pipeline", "web/src"]:
        for base, _dirs, names in os.walk(os.path.join(ROOT, folder)):
            paths += [os.path.join(base, name) for name in names if not name.endswith(".pyc")]
    for path in sorted(paths):
        digest.update(path[len(ROOT):].encode())
        digest.update(open(path, "rb").read())
    digest.update(SYNC_ENDPOINT.encode())
    return digest.hexdigest()


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

    # 1. The demo's Todo and Slack source, plus the gem's own files, with the source seams applied.
    app = os.path.join(B, "app-src")
    run([python, os.path.join(ROOT, "pipeline/carve.py"), T["GEM_SRC"], app])
    run([python, os.path.join(ROOT, "pipeline/vendor_gem.py"), T["GEM_SRC"], app])

    # 2. Roundhouse: Rails app -> Spinel project.
    emit = os.path.join(B, "emit")
    clean(emit)
    run([T["ROUNDHOUSE_BIN"], "--target", "spinel", "-o", emit, app], log="emit.log")
    toml = os.path.join(emit, "spin.toml")
    open(toml, "w").write(open(toml).read().replace('\nallocator = "jemalloc"', '\n# allocator = "jemalloc"  (wasm build: no jemalloc)'))

    # 3. One-shot entry and the single-threaded copy for wasm32-wasi.
    tree = os.path.join(B, "wasm-tree")
    clean(tree)
    run([python, os.path.join(ROOT, "pipeline/make_wasm_entry.py"), emit])
    run([python, os.path.join(ROOT, "pipeline/make_wasm_tree.py"), emit, tree])

    # 4. Spinel: Ruby -> C -> wasm, with SQLite linked in.
    sqlite = sqlite_library()
    os.makedirs(os.path.join(tree, "build"), exist_ok=True)
    flags = run(["spin", "flags"], cwd=tree, env=path_env).split()
    wasm = os.path.join(tree, "build/app.wasm")
    run(["spinel", "--target=wasm32-wasi", *flags, *SPINEL_FLAGS, "main_wasm.rb", "--link", "-L" + sqlite, "-o", wasm],
        cwd=tree, env={**path_env, "CPATH": T["SQLITE_SRC"]}, log="spinel.log")
    final = wasm
    if STRIP:
        final = os.path.join(tree, "build/app.stripped.wasm")
        run([os.path.join(T["WASI_SDK"], "bin/llvm-strip"), "-o", final, wasm])

    # 5. The host harness and the demo's own assets, laid out as a static site.
    web = os.path.join(ROOT, "web")
    modules = os.path.join(web, "node_modules")
    if not os.path.exists(modules):
        os.symlink(T["WEB_NODE_MODULES"], modules)
    digest = hashlib.sha256(open(final, "rb").read()).hexdigest()[:10]
    dist = os.path.join(web, "dist")
    run(["npx", "vite", "build"], cwd=web, env={"VITE_WASM_URL": f"/app-{digest}.wasm", "VITE_SYNC_ENDPOINT": SYNC_ENDPOINT}, log="vite.log")
    shutil.copy(final, os.path.join(dist, f"app-{digest}.wasm"))
    assets = os.path.join(dist, "assets")
    os.makedirs(os.path.join(assets, "controllers"), exist_ok=True)
    for name in os.listdir(os.path.join(emit, "static/assets")):
        shutil.copy(os.path.join(emit, "static/assets", name), assets)
    shutil.copy(os.path.join(app, "app/javascript/application.js"), assets)
    for name in os.listdir(os.path.join(app, "app/javascript/controllers")):
        shutil.copy(os.path.join(app, "app/javascript/controllers", name), os.path.join(assets, "controllers"))
    for name in ["turbo.min.js", "stimulus.min.js", "stimulus-loading.js"]:
        found = subprocess.run(["find", T["RAILS_GEMS"], "-name", name], stdout=subprocess.PIPE, text=True).stdout.split("\n")[0]
        shutil.copy(found, assets)
    print(f"built web/dist with app-{digest}.wasm ({os.path.getsize(final)} bytes)")
    open(stamp, "w").write(wanted)


if __name__ == "__main__":
    main()
