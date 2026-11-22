// The gem's change notice, as the worker's host reads it from /host/notify:
// "records_changed", then one "Type:id" line for each record that changed
// when the client could list them, followed by any "sync_notice:<json>" lines
// for quarantined rejections or LWW conflicts. `changes` is null when it could
// not list records, which means anything may have changed.
const NOTICE_PREFIX = "sync_notice:";

export function readNotice(text) {
  if (!text.startsWith("records_changed")) return { notified: false, changes: null, notices: [] };
  const lines = text.split("\n").slice(1).filter(Boolean);
  const changes = [];
  const notices = [];
  for (const line of lines) {
    if (line.startsWith(NOTICE_PREFIX)) {
      try {
        notices.push(JSON.parse(line.slice(NOTICE_PREFIX.length)));
      } catch {
        // Ignore malformed notice lines so record refresh still succeeds.
      }
      continue;
    }
    const at = line.indexOf(":");
    if (at > 0) changes.push({ type: line.slice(0, at), id: line.slice(at + 1) });
  }
  return {
    notified: true,
    changes: changes.length ? changes : null,
    notices,
  };
}
