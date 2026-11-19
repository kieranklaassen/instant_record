#!/usr/bin/env python3
"""Build the compiled app as a native library: demo source -> Roundhouse -> Spinel -> C -> lib + host.

usage: build_native.py                    (everything lands in <repo>/compiled/.build-native)
       build_native.py iphonesimulator    (libraries for the iOS simulator, in .build-native/iphonesimulator)

The first three steps are the browser build's (build.py). From there the app is compiled for
this machine and linked with native_shim.c into libinstant_record_app.a, which a native host
calls through native/instant_record_native.h. `host` beside it is the screenless host that
tests drive (native/host.c). The toolchain file needs SPINEL_HOME, ROUNDHOUSE_BIN, SQLITE_SRC
and CACHE.

For the iOS simulator there is no host program. Spinel ships its runtime built for this machine
only, so its sources and the three packages the app uses are compiled here for the simulator
into libspinel_rt.a, beside libinstant_record_app.a. The app in native/ios links both. This has
run on Linux x86_64 and macOS arm64, and for the simulator on arm64. Nothing here builds for a device.
"""
import os
import re
import subprocess
import sys

# Screens are staged for this build alone (carve.py).
os.environ["INSTANT_RECORD_NATIVE"] = "1"
import build

# native_shim.c holds one wrapper for each of these.
ENTRIES = [name.split(".")[1] for name in build.REACTOR_EXPORTS.split(",")] + ["render", "action", "open_database"]
CFLAGS = ["-O2", "-Wno-all", "-ffp-contract=off", "-DSP_INT_OVERFLOW_MODE_RAISE"]
SQLITE_CFLAGS = ["-O2", "-DSQLITE_THREADSAFE=0", "-DSQLITE_OMIT_LOAD_EXTENSION"]
PACKAGES = ("json", "stringio", "zlib")
IOS_MINIMUM = "17.0"
# Spinel's own flags for its runtime objects (SEC_FLAGS in its common.mk).
RUNTIME_CFLAGS = ["-O2", "-Wno-all", "-ffunction-sections", "-fdata-sections", "-ffp-contract=off"]


def simulator_cc():
    """clang for the iOS simulator on this Mac's architecture."""
    sdk = subprocess.run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], check=True, stdout=subprocess.PIPE, text=True).stdout.strip()
    return ["xcrun", "--sdk", "iphonesimulator", "clang", "-target", f"{os.uname().machine}-apple-ios{IOS_MINIMUM}-simulator", "-isysroot", sdk]


def makefile_list(spinel_home, name):
    """The words of `NAME = ...` in Spinel's Makefile, so the runtime's members are named once, there."""
    found = re.search(rf"^{name} = (.+)$", open(os.path.join(spinel_home, "Makefile")).read(), re.M)
    if not found:
        sys.exit(f"Spinel's Makefile has no {name}")
    return found.group(1).split()


def cross_runtime(cc, spinel_home, out, runtime, run):
    """Spinel's runtime and the app's packages, compiled for another target as its Makefile compiles them."""
    lib = os.path.join(spinel_home, "lib")
    regexp = ["-I" + os.path.join(lib, "regexp"), "-I" + os.path.join(lib, "regexp/shim")]
    sources = [(os.path.join(spinel_home, path), regexp) for path in makefile_list(spinel_home, "RE_SRC")]
    sources += [(os.path.join(lib, member + ".c"), ["-I" + lib, *regexp]) for member in makefile_list(spinel_home, "RT_MEMBERS")]
    objects = []
    for source, includes in sources:
        target = os.path.join(out, "rt_" + os.path.basename(source)[:-2] + ".o")
        run([*cc, *RUNTIME_CFLAGS, *includes, "-c", source, "-o", target], log="cc.log")
        objects.append(target)
    if os.path.exists(runtime):
        os.unlink(runtime)
    run(["ar", "rcs", runtime, *objects])
    packages = []
    for name in PACKAGES:
        folder = os.path.join(spinel_home, "packages", name)
        target = os.path.join(out, f"sp_{name}.o")
        run([*cc, *RUNTIME_CFLAGS, "-I" + lib, "-I" + folder, "-c", os.path.join(folder, f"sp_{name}.c"), "-o", target], log="cc.log")
        packages.append(target)
    return packages


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else ""
    if target not in ("", "iphonesimulator"):
        sys.exit("usage: build_native.py [iphonesimulator]")
    build.B = os.path.join(build.ROOT, ".build-native", target) if target else os.path.join(build.ROOT, ".build-native")
    T, B, run = build.T, build.B, build.run
    os.makedirs(B, exist_ok=True)
    os.makedirs(T["CACHE"], exist_ok=True)
    python = sys.executable
    pipeline = os.path.join(build.ROOT, "pipeline")
    spinel_home = T["SPINEL_HOME"]
    path_env = {"PATH": os.path.join(spinel_home, "bin") + os.pathsep + os.environ["PATH"]}
    cc = simulator_cc() if target else [os.environ.get("CC", "cc")]

    app, _emit, tree, _plan = build.emit_tree(python)
    print(run([python, os.path.join(pipeline, "make_native_entry.py"), tree, app, build.GEM_SRC]).strip())

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
        made = os.path.join(out, os.path.basename(source)[:-2] + ".o")
        run([*cc, *cflags, *includes, "-c", source, "-o", made], log="cc.log")
        objects.append(made)
    # The Spinel packages the app uses go into the archive. A host links Spinel's runtime
    # (libspinel_rt.a) beside it, as the host below does.
    if target:
        runtime = os.path.join(B, "libspinel_rt.a")
        objects += cross_runtime(cc, spinel_home, out, runtime, run)
    else:
        objects += [os.path.join(spinel_home, "packages", name, f"sp_{name}.o") for name in PACKAGES]
    library = os.path.join(B, "libinstant_record_app.a")
    if os.path.exists(library):
        os.unlink(library)
    run(["ar", "rcs", library, *objects])
    if target:
        print(f"built {library} and {runtime} for {target}")
        return
    host = os.path.join(B, "host")
    run([*cc, "-O2", *includes, os.path.join(pipeline, "native/host.c"), library,
         os.path.join(spinel_home, "lib/libspinel_rt.a"), "-lm", "-o", host], log="link.log")
    print(f"built {library} and {host} ({os.path.getsize(host)} bytes)")


if __name__ == "__main__":
    main()
