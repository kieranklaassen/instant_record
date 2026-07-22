#!/usr/bin/env bash
# Measurement harness for the wasm-size optimization.
# Prints one JSON object: app_wasm_bytes (primary, -1 on build failure),
# boot_ok / gem_packed (gates), core_wasm_bytes / gzip_bytes (diagnostics).
set -uo pipefail
cd "$(dirname "$0")/.."

export RBENV_VERSION=3.3.3
export PATH="$HOME/.local/bin:$PATH"   # wasi-vfs

fail() { echo "{\"app_wasm_bytes\": -1, \"boot_ok\": 0, \"gem_packed\": 0, \"core_wasm_bytes\": -1, \"gzip_bytes\": -1, \"error\": \"$1\"}"; exit 0; }

# Guard: never pack a previous wasm artifact into the new one (pack_directories
# may include public/).
rm -f public/app.wasm pwa/public/app.wasm

# Experiments that change the gem set touch tmp/wasmify to force a core rebuild;
# otherwise reuse the existing core module.
if [ ! -f tmp/wasmify/ruby-core.wasm ]; then
  bin/rails wasmify:build:core > tmp/measure_core.log 2>&1 || fail "core build failed"
fi

bin/rails wasmify:pack > tmp/measure_pack.log 2>&1 || fail "pack failed"
[ -f pwa/public/app.wasm ] || fail "no app.wasm produced"

APP_BYTES=$(stat -f%z pwa/public/app.wasm)
CORE_BYTES=$(stat -f%z tmp/wasmify/ruby-core.wasm 2>/dev/null || echo -1)

# Gate 1: the same config packed for wasmtime boots and serves a request.
# (Capture output, then match — grep -q on a live pipe + pipefail turns an
# early exit into a spurious failure via SIGPIPE.)
bin/rails wasmify:pack:core > tmp/measure_packcore.log 2>&1 || fail "pack:core failed"
VERIFY_OUT=$(bin/rails wasmify:pack:core:verify 2>&1 || true)
case "$VERIFY_OUT" in *"200"*) BOOT=1;; *) BOOT=0;; esac

# Gate 2: the instant_record gem is inside the bundle.
GEM=$(strings pwa/public/app.wasm 2>/dev/null | grep -cm1 "InstantRecord::Syncable" || true)

GZIP_BYTES=$(gzip -c pwa/public/app.wasm | wc -c | tr -d ' ')

echo "{\"app_wasm_bytes\": $APP_BYTES, \"boot_ok\": $BOOT, \"gem_packed\": $GEM, \"core_wasm_bytes\": $CORE_BYTES, \"gzip_bytes\": $GZIP_BYTES}"
