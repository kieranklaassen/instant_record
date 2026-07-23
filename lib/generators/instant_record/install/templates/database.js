import { PGlite, types } from "@electric-sql/pglite";

// Timestamps come back as raw Postgres strings rather than JavaScript Dates.
//
// Two things go wrong otherwise. Rails stores UTC wall-clock in a `timestamp
// without time zone` column, and the default parser builds a Date from that
// naive value as if it were *local* time — so reading it back shifts every
// timestamp by the machine's UTC offset. And a Date stringifies without
// sub-second precision, which silently truncates microseconds.
//
// Microseconds matter beyond display: a windowed model's history pages are
// keyset-paginated on (created_at, id), so a truncated cursor cannot be
// round-tripped into a query and scroll-up stalls. Handing Ruby the string lets
// ActiveRecord's own DateTime cast do the work, which reads it as UTC and keeps
// full precision.
const RAW_TIMESTAMPS = {
  [types.DATE]: (value) => value,
  [types.TIMESTAMP]: (value) => value,
  [types.TIMESTAMPTZ]: (value) => value,
};

export const setupPGliteDatabase = async () => {
  // IndexedDB persistence: survives reloads and service worker restarts.
  // relaxedDurability returns query results before the IndexedDB flush completes.
  const db = await PGlite.create("idb://instant_record", {
    relaxedDurability: true,
    parsers: RAW_TIMESTAMPS,
  });

  console.log("Running PGlite (Postgres in Wasm)");
  return db;
};
