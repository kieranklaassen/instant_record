// Node-only schema-aware SQLite checkpoint redactor using Node's built-in
// `node:sqlite`. Redacts PII columns per table, redacts `changes_payload` JSON
// inside `instant_record_outbox` by `record_type`, redacts `identity` in
// `instant_record_sync_metadata`, and runs VACUUM so deleted raw PII bytes do
// not linger in SQLite freelist pages.
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { Redactor } from "./redactor.js";
import { sha256Hex } from "./sha256.js";

function quoteIdent(name) {
  return `"${String(name).replaceAll('"', '""')}"`;
}

export function redactSqliteBytes(dbBytes, redactor = new Redactor()) {
  const original = dbBytes instanceof Uint8Array ? dbBytes : new Uint8Array(dbBytes);
  const originalDigest = sha256Hex(original);
  const dir = mkdtempSync(join(tmpdir(), "irtrace-redact-"));
  const file = join(dir, "checkpoint.sqlite3");
  const redactedColumns = {};

  try {
    writeFileSync(file, original);
    const db = new DatabaseSync(file);
    try {
      const tables = db
        .prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        .all()
        .map((row) => row.name);

      for (const table of tables) {
        if (table === "schema_migrations" || table === "ar_internal_metadata") continue;

        if (table === "instant_record_sync_metadata") {
          const rows = db.prepare(`SELECT key, value FROM ${quoteIdent(table)}`).all();
          const update = db.prepare(`UPDATE ${quoteIdent(table)} SET value = ? WHERE key = ?`);
          for (const row of rows) {
            if (row.key === "identity" && row.value) {
              const next = redactor.pseudonymize(row.value, "identity");
              update.run(next, row.key);
              redactor.noteRedactedColumn(table, "identity");
              redactedColumns[table] ||= [];
              if (!redactedColumns[table].includes("identity")) redactedColumns[table].push("identity");
            }
          }
          continue;
        }

        if (table === "instant_record_outbox") {
          const rows = db.prepare(`SELECT id, record_type, changes_payload FROM ${quoteIdent(table)}`).all();
          const update = db.prepare(`UPDATE ${quoteIdent(table)} SET changes_payload = ? WHERE id = ?`);
          for (const row of rows) {
            if (!row.changes_payload) continue;
            try {
              const parsed = JSON.parse(row.changes_payload);
              const redacted = redactor.redactRecordAttributes(row.record_type || "*", parsed);
              const serialized = JSON.stringify(redacted);
              if (serialized !== row.changes_payload) {
                update.run(serialized, row.id);
                redactedColumns[table] ||= [];
                if (!redactedColumns[table].includes("changes_payload")) redactedColumns[table].push("changes_payload");
              }
            } catch {
              // Non-JSON payload left untouched.
            }
          }
          continue;
        }

        const columns = db.prepare(`PRAGMA table_info(${quoteIdent(table)})`).all();
        const piiCols = columns
          .map((col) => col.name)
          .filter((name) => redactor.isPiiColumn(table, name));
        if (piiCols.length === 0) continue;

        const selectSql = `SELECT rowid AS __ir_rowid, ${piiCols.map(quoteIdent).join(", ")} FROM ${quoteIdent(table)}`;
        const rows = db.prepare(selectSql).all();
        const setClause = piiCols.map((col) => `${quoteIdent(col)} = ?`).join(", ");
        const updateStmt = db.prepare(`UPDATE ${quoteIdent(table)} SET ${setClause} WHERE rowid = ?`);

        for (const row of rows) {
          const values = piiCols.map((col) => {
            const val = row[col];
            if (val === null || val === undefined || val === "") return val;
            return redactor.pseudonymize(val, col);
          });
          updateStmt.run(...values, row.__ir_rowid);
        }

        redactedColumns[table] = piiCols.slice().sort();
        for (const col of piiCols) redactor.noteRedactedColumn(table, col);
      }

      db.exec("VACUUM");
    } finally {
      db.close();
    }

    const bytes = new Uint8Array(readFileSync(file));
    return {
      bytes,
      digest: sha256Hex(bytes),
      originalDigest,
      redactedColumns,
    };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}
