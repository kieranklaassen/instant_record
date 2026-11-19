// The ids from `anchorId` to `cursorId` in `ids`, both included, in list
// order whichever way the range runs. An anchor that left the list leaves
// only the cursor's row.
export function rangeBetween(ids, anchorId, cursorId) {
  const cursor = ids.indexOf(cursorId)
  if (cursor < 0) return []
  const anchor = ids.indexOf(anchorId)
  if (anchor < 0) return [cursorId]
  return ids.slice(Math.min(anchor, cursor), Math.max(anchor, cursor) + 1)
}
