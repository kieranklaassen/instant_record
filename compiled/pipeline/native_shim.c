/* Native reactor bridge for Spinel (--ext-init app_boot): reactor_shim.c for a
   host that links the app as a library. The browser's host trades strings with
   Ruby through a WASI directory. Here they pass through named slots in memory,
   which Ruby reaches as NativeHost (EntryBuilder). */
#include "app.h"
#include "instant_record_native.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#ifndef __APPLE__
#include <sys/random.h>
#endif

enum { IN, OUT, NOTIFY, REQUEST, RESPONSE, SLOTS };
static const char *const names[SLOTS] = { "in", "out", "notify", "request", "response" };
static char *slots[SLOTS];
static char error[512];
static ir_exchange_fn exchange;
static void *exchange_context;
/* The app boots once in a process: Spinel's app_boot() may not run twice. */
static enum { ASLEEP, UP, BROKEN } state;

static void put(int slot, const char *value) {
  char *copy = strdup(value ? value : "");
  if (!copy) abort();
  free(slots[slot]);
  slots[slot] = copy;
}

static int slot_named(const char *name) {
  for (int slot = 0; slot < SLOTS; slot++)
    if (strcmp(names[slot], name) == 0) return slot;
  return -1;
}

const char *ir_host_take(const char *name) {
  int slot = slot_named(name);
  return slot >= 0 && slots[slot] ? slots[slot] : "";
}

void ir_host_give(const char *name, const char *value) {
  int slot = slot_named(name);
  if (slot < 0) return;
  put(slot, value);
  if (slot == REQUEST) put(RESPONSE, exchange ? exchange(slots[REQUEST], exchange_context) : "0\n");
}

static void call_request(void *ctx)   { (void)ctx; sp_NativeBridge_s_handle_request(); }
static void call_plan(void *ctx)      { (void)ctx; sp_NativeBridge_s_sync_plan(); }
static void call_sync(void *ctx)      { (void)ctx; sp_NativeBridge_s_handle_sync(); }
static void call_stream(void *ctx)    { (void)ctx; sp_NativeBridge_s_handle_stream(); }
static void call_history(void *ctx)   { (void)ctx; sp_NativeBridge_s_history(); }
static void call_cursor(void *ctx)    { (void)ctx; sp_NativeBridge_s_cursor(); }
static void call_export_outbox(void *ctx) { (void)ctx; sp_NativeBridge_s_export_outbox(); }
static void call_import_outbox(void *ctx) { (void)ctx; sp_NativeBridge_s_import_outbox(); }
static void call_branch_outbox(void *ctx) { (void)ctx; sp_NativeBridge_s_branch_outbox(); }
static void call_branch_replay(void *ctx) { (void)ctx; sp_NativeBridge_s_branch_replay(); }
static void call_render(void *ctx)    { (void)ctx; sp_NativeBridge_s_render(); }
static void call_action(void *ctx)    { (void)ctx; sp_NativeBridge_s_action(); }
static void call_open(void *ctx)      { (void)ctx; sp_NativeBridge_s_open(); }
static void call_boot(void *ctx)      { (void)ctx; app_boot(); }

static const struct { const char *name; void (*fn)(void *); } entries[] = {
  { "request", call_request }, { "sync_plan", call_plan }, { "sync", call_sync },
  { "stream", call_stream },   { "history", call_history }, { "cursor", call_cursor },
  { "export_outbox", call_export_outbox }, { "import_outbox", call_import_outbox },
  { "branch_outbox", call_branch_outbox }, { "branch_replay", call_branch_replay },
  { "render", call_render },   { "action", call_action },   { "open", call_open },
};

static int run_guarded(void (*fn)(void *)) {
  const char *cls = NULL;
  const char *msg = NULL;
  error[0] = 0;
  if (app_boot_try(fn, NULL, &cls, &msg)) {
    snprintf(error, sizeof error, "%s: %s", cls ? cls : "Error", msg ? msg : "");
    return 1;
  }
  return 0;
}

void ir_set_exchange(ir_exchange_fn fn, void *context) {
  exchange = fn;
  exchange_context = context;
}

/* The iOS SDK has no <sys/random.h>, and arc4random_buf cannot fail. */
static int random_bytes(unsigned char *bytes, size_t size) {
#ifdef __APPLE__
  arc4random_buf(bytes, size);
  return 0;
#else
  return getentropy(bytes, size);
#endif
}

/* The runtime signs cookies with SECRET_KEY_BASE and, when there is none, keeps
   one in a file under the working directory. A native host serves no cookies
   and may not be able to write there, so each boot gets a key of its own. */
static void fresh_secret(void) {
  unsigned char bytes[32];
  char hex[sizeof bytes * 2 + 1];
  if (getenv("SECRET_KEY_BASE") || random_bytes(bytes, sizeof bytes) != 0) return;
  for (size_t i = 0; i < sizeof bytes; i++) snprintf(hex + i * 2, 3, "%02x", bytes[i]);
  setenv("SECRET_KEY_BASE", hex, 1);
}

static int refuse(const char *why) {
  snprintf(error, sizeof error, "%s", why);
  return 1;
}

static int asleep(void) {
  if (state == UP) return 0;
  return refuse(state == BROKEN ? "The app did not boot, and cannot boot again in this process" : "Call ir_boot first");
}

int ir_boot(const char *database_path) {
  if (state != ASLEEP) return refuse("The app boots once. Open another database with ir_open");
  setenv("BLOG_DB", database_path, 1);
  fresh_secret();
  state = run_guarded(call_boot) ? BROKEN : UP;
  return state != UP;
}

int ir_open(const char *database_path) {
  return ir_call("open", database_path) ? 0 : 1;
}

const char *ir_call(const char *entry, const char *input) {
  if (asleep()) return NULL;
  for (size_t i = 0; i < sizeof entries / sizeof entries[0]; i++) {
    if (strcmp(entries[i].name, entry) != 0) continue;
    put(IN, input);
    put(OUT, "");
    put(NOTIFY, "");
    return run_guarded(entries[i].fn) ? NULL : slots[OUT];
  }
  snprintf(error, sizeof error, "No entry named %s", entry);
  return NULL;
}

const char *ir_notice(void) { return slots[NOTIFY] ? slots[NOTIFY] : ""; }
const char *ir_error(void) { return error; }
