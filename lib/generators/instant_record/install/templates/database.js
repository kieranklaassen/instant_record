import { PGlite } from "@electric-sql/pglite";

export const setupPGliteDatabase = async () => {
  // IndexedDB persistence: survives reloads and service worker restarts.
  // relaxedDurability returns query results before the IndexedDB flush completes.
  const db = await PGlite.create("idb://instant_record", {
    relaxedDurability: true,
  });

  console.log("Running PGlite (Postgres in Wasm)");
  return db;
};
