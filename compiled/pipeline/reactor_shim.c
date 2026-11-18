/* WASI reactor bridge for Spinel (--ext-init app_boot).
   Boots the Ruby runtime and SQLite connection once per worker lifetime via
   wasm_boot(), then handles requests and sync passes on the live instance. */
#include "app.h"
#include <stdio.h>

static void call_request(void *ctx) {
  (void)ctx;
  sp_WasmBridge_s_handle_request();
}

static void call_sync(void *ctx) {
  (void)ctx;
  sp_WasmBridge_s_handle_sync();
}

static int run_guarded(void (*fn)(void *)) {
  const char *cls = NULL;
  const char *msg = NULL;
  if (app_boot_try(fn, NULL, &cls, &msg)) {
    fprintf(stderr, "%s: %s\n", cls ? cls : "Error", msg ? msg : "");
    fflush(stderr);
    return 1;
  }
  return 0;
}

__attribute__((export_name("wasm_boot")))
void wasm_boot(void) {
  app_boot();
}

__attribute__((export_name("wasm_request")))
int wasm_request(void) {
  return run_guarded(call_request);
}

__attribute__((export_name("wasm_sync")))
int wasm_sync(void) {
  return run_guarded(call_sync);
}
