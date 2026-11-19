// Where focus belongs in `ids`, given the row that had it and where that row
// last stood. A row that left the list (archived here, or by a teammate)
// hands focus to the row that took its place, never to the top.
export function resolveFocus(ids, id, index) {
  if (!ids.length) return { id: null, index: 0 }
  const at = ids.indexOf(id)
  if (at >= 0) return { id, index: at }
  const next = Math.min(Math.max(index, 0), ids.length - 1)
  return { id: ids[next], index: next }
}
