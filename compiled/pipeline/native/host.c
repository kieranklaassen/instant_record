/* A host with no screen: it runs the compiled app for a driver on the other end
   of its standard input and output, so a test can stand where the phone and
   the network would be.

     usage: host <database file>    boot on that file
            host -                  do not boot: the driver sends boot itself

   The driver sends   call <entry> <bytes>\n<input>
   and reads          ok <out bytes> <notice bytes>\n<out><notice>
   or                 error <bytes>\n<message>

   `boot <bytes>\n<path>` and `open <bytes>\n<path>` are ir_boot and ir_open,
   answered the same way with nothing in <out>.

   While a call runs the app may ask for the network. The host then writes
   exchange <bytes>\n<request> and reads <bytes>\n<response> from the driver. */
#include "instant_record_native.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *read_bytes(size_t size) {
  char *bytes = malloc(size + 1);
  if (!bytes || fread(bytes, 1, size, stdin) != size) exit(2);
  bytes[size] = 0;
  return bytes;
}

static const char *ask_driver(const char *request, void *context) {
  static char *response;
  size_t size;
  (void)context;
  printf("exchange %zu\n%s", strlen(request), request);
  fflush(stdout);
  if (scanf("%zu", &size) != 1 || getchar() != '\n') exit(2);
  free(response);
  response = read_bytes(size);
  return response;
}

static void fail(void) {
  printf("error %zu\n%s", strlen(ir_error()), ir_error());
  fflush(stdout);
}

static void done(int failed) {
  if (failed) { fail(); return; }
  printf("ok 0 0\n");
  fflush(stdout);
}

int main(int argc, char **argv) {
  char verb[8], entry[32];
  size_t size;
  if (argc != 2) return 64;
  ir_set_exchange(ask_driver, NULL);
  if (strcmp(argv[1], "-") == 0) done(0);
  else if (ir_boot(argv[1])) { fail(); return 1; }
  else done(0);
  while (scanf(" %7s", verb) == 1) {
    int call = strcmp(verb, "call") == 0;
    if (call && scanf(" %31s", entry) != 1) return 2;
    if (scanf(" %zu", &size) != 1 || getchar() != '\n') return 2;
    char *input = read_bytes(size);
    if (call) {
      const char *out = ir_call(entry, input);
      if (!out) fail();
      else {
        printf("ok %zu %zu\n%s%s", strlen(out), strlen(ir_notice()), out, ir_notice());
        fflush(stdout);
      }
    } else if (strcmp(verb, "boot") == 0) done(ir_boot(input));
    else if (strcmp(verb, "open") == 0) done(ir_open(input));
    else return 2;
    free(input);
  }
  return 0;
}
