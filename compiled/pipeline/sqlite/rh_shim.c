/* Hand-written: 32-bit entry points for the two SQLite calls the emitted runtime declares with
   `long`, which is 32 bits on wasm32 while SQLite's own signatures are 64-bit. */
#include "sqlite3.h"
int rh_sqlite3_bind_int64(sqlite3_stmt *stmt, int index, long value) { return sqlite3_bind_int64(stmt, index, (sqlite3_int64)value); }
long rh_sqlite3_last_insert_rowid(sqlite3 *db) { return (long)sqlite3_last_insert_rowid(db); }
