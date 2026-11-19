/* A host with no screen: it runs the compiled app for a driver on the other end
   of its standard input and output, so a test can stand where the phone and
   the network would be.

     usage: host <database file>

   The driver sends   call <entry> <bytes>\n<input>
   and reads          ok <out bytes> <notice bytes>\n<out><notice>
   or                 error <bytes>\n<message>

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

int main(int argc, char **argv) {
  char entry[32];
  size_t size;
  if (argc != 2) return 64;
  ir_set_exchange(ask_driver, NULL);
  if (ir_boot(argv[1])) { fail(); return 1; }
  printf("ok 0 0\n");
  fflush(stdout);
  while (scanf(" call %31s %zu", entry, &size) == 2 && getchar() == '\n') {
    char *input = read_bytes(size);
    const char *out = ir_call(entry, input);
    free(input);
    if (!out) { fail(); continue; }
    printf("ok %zu %zu\n%s%s", strlen(out), strlen(ir_notice()), out, ir_notice());
    fflush(stdout);
  }
  return 0;
}
