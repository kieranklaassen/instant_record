/* WASI reactor bridge for Spinel (--ext-init app_boot).
   Boots the Ruby runtime and SQLite connection once per worker lifetime via
   wasm_boot(), then handles requests, outbox drains, and async-fetched change
   batches on the live instance. */
#include "app.h"
#include <stdio.h>

static void call_request(void *ctx) { (void)ctx; sp_WasmBridge_s_handle_request(); }
static void call_plan(void *ctx)    { (void)ctx; sp_WasmBridge_s_sync_plan(); }
static void call_sync(void *ctx)    { (void)ctx; sp_WasmBridge_s_handle_sync(); }
static void call_stream(void *ctx)  { (void)ctx; sp_WasmBridge_s_handle_stream(); }
static void call_history(void *ctx) { (void)ctx; sp_WasmBridge_s_history(); }
static void call_cursor(void *ctx)  { (void)ctx; sp_WasmBridge_s_cursor(); }
static void call_notices(void *ctx) { (void)ctx; sp_WasmBridge_s_notices(); }

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
void wasm_boot(void) { app_boot(); }

__attribute__((export_name("wasm_request")))
int wasm_request(void) { return run_guarded(call_request); }

__attribute__((export_name("wasm_sync_plan")))
int wasm_sync_plan(void) { return run_guarded(call_plan); }

__attribute__((export_name("wasm_sync")))
int wasm_sync(void) { return run_guarded(call_sync); }

__attribute__((export_name("wasm_stream")))
int wasm_stream(void) { return run_guarded(call_stream); }

__attribute__((export_name("wasm_cursor")))
int wasm_cursor(void) { return run_guarded(call_cursor); }


__attribute__((export_name("wasm_history")))
int wasm_history(void) { return run_guarded(call_history); }

__attribute__((export_name("wasm_notices")))
int wasm_notices(void) { return run_guarded(call_notices); }
