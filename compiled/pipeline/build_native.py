#!/usr/bin/env python3
"""Build the compiled app as a native library: demo source -> Roundhouse -> Spinel -> C -> lib + host.

usage: build_native.py            (everything lands in <repo>/compiled/.build-native)

The first three steps are the browser build's (build.py). From there the app is compiled for
this machine and linked with native_shim.c into libinstant_record_app.a, which a native host
calls through native/instant_record_native.h. `host` beside it is the screenless host that
tests drive (native/host.c). The toolchain file needs SPINEL_HOME, ROUNDHOUSE_BIN, SQLITE_SRC
and CACHE. This has run on Linux x86_64 only: nothing here builds for iOS yet.
"""
import os
import sys

# Screens are staged for this build alone (carve.py).
os.environ["INSTANT_RECORD_NATIVE"] = "1"
import build

# native_shim.c holds one wrapper for each of these.
ENTRIES = [name.split(".")[1] for name in build.REACTOR_EXPORTS.split(",")] + ["render", "action"]
CFLAGS = ["-O2", "-Wno-all", "-ffp-contract=off", "-DSP_INT_OVERFLOW_MODE_RAISE"]
SQLITE_CFLAGS = ["-O2", "-DSQLITE_THREADSAFE=0", "-DSQLITE_OMIT_LOAD_EXTENSION"]


def main():
    build.B = os.path.join(build.ROOT, ".build-native")
    T, B, run = build.T, build.B, build.run
    os.makedirs(B, exist_ok=True)
    os.makedirs(T["CACHE"], exist_ok=True)
    python = sys.executable
    pipeline = os.path.join(build.ROOT, "pipeline")
    spinel_home = T["SPINEL_HOME"]
    path_env = {"PATH": os.path.join(spinel_home, "bin") + os.pathsep + os.environ["PATH"]}
    cc = os.environ.get("CC", "cc")

    app, _emit, tree, _plan = build.emit_tree(python)
    print(run([python, os.path.join(pipeline, "make_native_entry.py"), tree, app]).strip())

    out = os.path.join(tree, "build")
    os.makedirs(out, exist_ok=True)
    app_c = os.path.join(out, "app.c")
    flags = run(["spin", "flags"], cwd=tree, env=path_env).split()
    run(["spinel", "-c", "--force", "--ext-init", "app_boot",
         "--ext-entry", ",".join("NativeBridge." + entry for entry in ENTRIES),
         *flags, "main_native.rb", "-o", app_c],
        cwd=tree, env={**path_env, "CPATH": T["SQLITE_SRC"]}, log="spinel.log")

    includes = ["-I" + os.path.join(spinel_home, "lib"), "-I" + os.path.join(spinel_home, "lib/regexp"),
                "-I" + T["SQLITE_SRC"], "-I" + out, "-I" + os.path.join(pipeline, "native")]
    objects = []
    for source, cflags in [(app_c, CFLAGS), (os.path.join(pipeline, "native_shim.c"), CFLAGS),
                           (os.path.join(pipeline, "sqlite/rh_shim.c"), CFLAGS),
                           (os.path.join(T["SQLITE_SRC"], "sqlite3.c"), SQLITE_CFLAGS)]:
        target = os.path.join(out, os.path.basename(source)[:-2] + ".o")
        run([cc, *cflags, *includes, "-c", source, "-o", target], log="cc.log")
        objects.append(target)
    # The Spinel packages the app uses go into the archive. A host links Spinel's runtime
    # (libspinel_rt.a) beside it, as the host below does.
    objects += [os.path.join(spinel_home, "packages", name, f"sp_{name}.o") for name in ("json", "stringio", "zlib")]
    library = os.path.join(B, "libinstant_record_app.a")
    if os.path.exists(library):
        os.unlink(library)
    run(["ar", "rcs", library, *objects])
    host = os.path.join(B, "host")
    run([cc, "-O2", *includes, os.path.join(pipeline, "native/host.c"), library,
         os.path.join(spinel_home, "lib/libspinel_rt.a"), "-lm", "-o", host], log="link.log")
    print(f"built {library} and {host} ({os.path.getsize(host)} bytes)")


if __name__ == "__main__":
    main()
