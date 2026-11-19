/* A compiled InstantRecord app, as a native host calls it.

   Every call runs Ruby on the calling thread and none may overlap: give the
   app one serial queue. Strings are UTF-8 and NUL-terminated. A returned
   string belongs to the library and holds until the next call. */
#ifndef INSTANT_RECORD_NATIVE_H
#define INSTANT_RECORD_NATIVE_H

/* The app asks for the network through this during a "sync" call. `request`
   is "METHOD URL\n" and then the body. Answer with the status on the first
   line and then the response body, or "0\n" when the network failed. */
typedef const char *(*ir_exchange_fn)(const char *request, void *context);
void ir_set_exchange(ir_exchange_fn exchange, void *context);

/* Open the SQLite file at `database_path`, creating it and its tables when
   it is new. Call once, before anything else. Returns 0 when the app is up. */
int ir_boot(const char *database_path);

/* Run one entry point with `input` and return what it wrote, or NULL when
   Ruby raised (ir_error says what).

     "render"     input "screen\narg"                  the screen as JSON
     "action"     input "screen\narg\naction\narg"     a tap; render again after
     "sync"       input the sync endpoint's address    one pass: push, then pull
     "stream"     input a text/event-stream chunk      changes the host fetched
     "sync_plan", "cursor", "history", "request"       as the browser host uses them */
const char *ir_call(const char *entry, const char *input);

/* What changed during the last call: empty, or "records_changed" and then
   one "Type:id" line for each record when the app could list them. */
const char *ir_notice(void);

const char *ir_error(void);

#endif
