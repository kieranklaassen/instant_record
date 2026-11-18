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
REPO_ROOT = os.path.dirname(ROOT)

# ── build knobs ──────────────────────────────────────────────────────────────
SPINEL_FLAGS = []  # extra flags for `spinel --target=wasm32-wasi`
WASM_OPT_LEVEL = "-O2"
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
GEM_SRC = os.environ.get("GEM_SRC") or REPO_ROOT
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
    """Everything a build depends on inside this checkout, so an unchanged checkout is not rebuilt."""
    digest = hashlib.sha256()
    paths = [os.path.join(ROOT, "toolchain.env"), os.path.join(ROOT, "web/index.html"), os.path.join(ROOT, "web/vite.config.js")]
    for base_root, folders in [(ROOT, ["pipeline", "web/src"]), (GEM_SRC, ["lib/instant_record", "demo/app"])]:
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
        "--ext-entry", "WasmBridge.handle_request,WasmBridge.handle_sync",
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
    run([python, os.path.join(ROOT, "pipeline/carve.py"), GEM_SRC, app])
    run([python, os.path.join(ROOT, "pipeline/vendor_gem.py"), GEM_SRC, app])

    # 2. Roundhouse: Rails app -> Spinel project.
    emit = os.path.join(B, "emit")
    clean(emit)
    run([T["ROUNDHOUSE_BIN"], "--target", "spinel", "-o", emit, app], log="emit.log")
    toml = os.path.join(emit, "spin.toml")
    open(toml, "w").write(open(toml).read().replace('\nallocator = "jemalloc"', '\n# allocator = "jemalloc"  (wasm build: no jemalloc)'))

    # 3. Persistent reactor entry and the single-threaded copy for wasm32-wasi.
    tree = os.path.join(B, "wasm-tree")
    clean(tree)
    run([python, os.path.join(ROOT, "pipeline/make_wasm_entry.py"), emit])
    run([python, os.path.join(ROOT, "pipeline/make_wasm_tree.py"), emit, tree])

    # 4. Spinel: Ruby -> C -> WASI reactor wasm, with SQLite linked in.
    sqlite = sqlite_library()
    flags = run(["spin", "flags"], cwd=tree, env=path_env).split()
    wasm = compile_reactor(tree, flags, sqlite, path_env)
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
