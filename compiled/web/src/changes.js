// The gem's change notice, as the worker's host reads it from /host/notify:
// "records_changed", then one "Type:id" line for each record that changed
// when the client could list them. `changes` is null when it could not, which
// means anything may have changed.
export function readNotice(text) {
  if (!text.startsWith("records_changed")) return { notified: false, changes: null };
  const lines = text.split("\n").slice(1).filter(Boolean);
  if (lines.length === 0) return { notified: true, changes: null };
  return {
    notified: true,
    changes: lines.map((line) => {
      const at = line.indexOf(":");
      return { type: line.slice(0, at), id: line.slice(at + 1) };
    }),
  };
}
