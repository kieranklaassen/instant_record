import { createElement, useEffect, useMemo, useRef, useState } from "react"
import { Virtuoso } from "react-virtuoso"

// Virtuoso numbers rows from `firstItemIndex`. Lowering it by the rows that
// arrived above the reader keeps the row they are on where it is.
const START = 1_000_000
// Rows in the first draw, before the list knows its height: a screenful.
const FIRST_DRAW = 20

function useSteadyStart(rows, anchor) {
  const before = useRef({ start: START, at: new Map() })
  return useMemo(() => {
    const was = before.current
    const at = new Map(rows.map((row, index) => [row.id, index]))
    let start = was.start
    const held = anchor.current
    if (held && was.at.has(held) && at.has(held)) start -= at.get(held) - was.at.get(held)
    before.current = { start, at }
    return start
  }, [rows, anchor])
}

// A virtual list for rows that change under the reader: sync adds rows above
// and removes rows anywhere, and the row being read stays where it is.
//
//   rows      objects with an `id`, in order
//   children  (row, index) => the row's element
//   onEnd     called as the reader nears the last row (useLiveWindow's `older`)
//   register  from useKeyboardNavigation, so keys can bring any row into view
//   openAt    the index to open on, read once (a reload returns to its row)
//   onTop     called with whether the list is scrolled to its top
export default function LiveList({ rows, children, onEnd, register, openAt = 0, onTop, className }) {
  const list = useRef(null)
  const anchor = useRef(null)
  const start = useSteadyStart(rows, anchor)
  const now = useRef({})
  now.current = { rows, start }

  // Opened at its top, the list's first draw holds rows. Left to itself it
  // draws empty, measures its box and draws again, and the reader sees the
  // empty one. Opened deeper it has to scroll before it can show a row, so
  // there it keeps the empty draw.
  const [opening] = useState(() => (openAt > 0
    ? { initialTopMostItemIndex: { index: Math.min(openAt, rows.length - 1), align: "center" } }
    : { initialItemCount: Math.min(rows.length, FIRST_DRAW) }))

  useEffect(() => register?.((index) => list.current?.scrollIntoView({ index, behavior: "auto" })), [register])

  // Plain createElement, so the package needs no JSX transform where it is installed.
  return createElement(Virtuoso, {
    ref: list,
    className,
    data: rows,
    firstItemIndex: start,
    ...opening,
    computeItemKey: (_, row) => row.id,
    increaseViewportBy: 600,
    endReached: () => onEnd?.(),
    atTopStateChange: onTop,
    rangeChanged: ({ startIndex }) => {
      const { rows, start } = now.current
      // At the top a new row should show, so nothing is held there.
      anchor.current = startIndex - start > 0 ? rows[startIndex - start]?.id : null
    },
    itemContent: (index, row) => children(row, index - now.current.start),
  })
}
