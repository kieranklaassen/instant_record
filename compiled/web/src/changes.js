// Typed row-delta bus helpers shared by the compiled worker, AppHost, and main.js.
//
// Wire format from /host/notify and ir_notice():
//   ""                        -> not notified
//   "records_changed"         -> wildcard: anything may have changed (changes: null)
//   "records_changed\n<line>" -> one compact JSON delta per line:
//                                {"type","id","op","changed_columns","attrs"}
//                                (or legacy "Type:id" lines, normalized cleanly)

export function normalizeDelta(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  if (typeof raw.type !== "string" || !raw.type) return null;
  if (raw.id === undefined || raw.id === null || raw.id === "") return null;
  return {
    type: raw.type,
    id: String(raw.id),
    op: typeof raw.op === "string" && raw.op ? raw.op : "update",
    changed_columns: Array.isArray(raw.changed_columns) ? raw.changed_columns.map(String) : [],
    attrs: raw.attrs && typeof raw.attrs === "object" && !Array.isArray(raw.attrs) ? raw.attrs : {},
  };
}

export function readNotice(text) {
  if (typeof text !== "string" || !text.startsWith("records_changed")) {
    return { notified: false, changes: null };
  }
  const lines = text.split("\n").slice(1).filter(Boolean);
  if (lines.length === 0) return { notified: true, changes: null };

  const changes = [];
  for (const line of lines) {
    if (line.startsWith("{")) {
      try {
        const delta = normalizeDelta(JSON.parse(line));
        if (!delta) return { notified: true, changes: null };
        changes.push(delta);
      } catch {
        return { notified: true, changes: null };
      }
    } else {
      const at = line.indexOf(":");
      if (at <= 0) return { notified: true, changes: null };
      changes.push({
        type: line.slice(0, at),
        id: line.slice(at + 1),
        op: null,
        changed_columns: [],
        attrs: {},
      });
    }
  }
  return { notified: true, changes };
}

export function encodeBroadcast(revision, changes = null) {
  return {
    revision: revision ?? null,
    changes: Array.isArray(changes) ? changes : null,
  };
}

export function decodeBroadcast(message) {
  if (typeof message === "number") {
    return { revision: message, changes: null };
  }
  if (!message || typeof message !== "object") {
    return { revision: null, changes: null };
  }
  const rawChanges = Array.isArray(message.changes) ? message.changes : null;
  if (!rawChanges) {
    return { revision: message.revision ?? null, changes: null };
  }
  const changes = [];
  for (const item of rawChanges) {
    const delta = normalizeDelta(item);
    if (!delta) return { revision: message.revision ?? null, changes: null };
    changes.push(delta);
  }
  return { revision: message.revision ?? null, changes };
}

export function parseReads(text) {
  if (typeof text !== "string" || !text.trim()) return null;
  try {
    const parsed = JSON.parse(text);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
    const tables = Array.isArray(parsed.tables) ? parsed.tables.map(String) : [];
    const models = Array.isArray(parsed.models) ? parsed.models.map(String) : [];
    const partitions = parsed.partitions && typeof parsed.partitions === "object" && !Array.isArray(parsed.partitions)
      ? parsed.partitions
      : {};
    return { tables, models, partitions };
  } catch {
    return null;
  }
}

export function mergeReads(base, extra) {
  if (!extra) return base || null;
  if (!base) return extra;

  const tables = [...new Set([...(base.tables || []), ...(extra.tables || [])])].sort();
  const models = [...new Set([...(base.models || []), ...(extra.models || [])])].sort();
  const baseKeys = new Set([...(base.models || []), ...(base.tables || [])]);
  const extraKeys = new Set([...(extra.models || []), ...(extra.tables || [])]);
  const allKeys = new Set([...baseKeys, ...extraKeys]);
  const partitions = {};

  for (const key of allKeys) {
    const inBase = baseKeys.has(key);
    const inExtra = extraKeys.has(key);
    const a = base.partitions?.[key];
    const b = extra.partitions?.[key];

    if (inBase && inExtra) {
      if (!a || !b) continue; // unconstrained in at least one read -> whole-table dependency
      const merged = {};
      for (const [col, vals] of Object.entries(a)) {
        if (!Object.prototype.hasOwnProperty.call(b, col)) continue;
        merged[col] = [...new Set([...vals.map(String), ...b[col].map(String)])].sort();
      }
      if (Object.keys(merged).length) partitions[key] = merged;
    } else if (inBase && a && Object.keys(a).length) {
      partitions[key] = a;
    } else if (inExtra && b && Object.keys(b).length) {
      partitions[key] = b;
    }
  }

  return { tables, models, partitions };
}

export function affectsReads(changes, reads) {
  if (!changes || !reads) return true;
  if (changes.length === 0) return false;

  const models = Array.isArray(reads.models) ? reads.models : [];
  const tables = Array.isArray(reads.tables) ? reads.tables : [];
  if (models.length === 0 && tables.length === 0) return false;

  const partitions = reads.partitions && typeof reads.partitions === "object" ? reads.partitions : {};

  return changes.some((delta) => {
    if (!delta || typeof delta !== "object") return true;
    const type = delta.type || "";
    const table = delta.table || "";
    let matchedKey = null;
    if (type && models.includes(type)) matchedKey = type;
    else if (table && tables.includes(table)) matchedKey = table;
    if (!matchedKey) return false;

    const constraints = partitions[matchedKey] || (table ? partitions[table] : null);
    if (!constraints || typeof constraints !== "object") return true;

    const attrs = delta.attrs;
    if (!attrs || typeof attrs !== "object") return true;
    const changedCols = Array.isArray(delta.changed_columns) ? delta.changed_columns : [];

    for (const [col, allowed] of Object.entries(constraints)) {
      if (delta.op === "update" && changedCols.includes(col)) continue;
      if (!Object.prototype.hasOwnProperty.call(attrs, col)) continue;
      const val = attrs[col];
      if (val === null || val === undefined) continue;
      if (!Array.isArray(allowed) || !allowed.map(String).includes(String(val))) {
        return false;
      }
    }
    return true;
  });
}
