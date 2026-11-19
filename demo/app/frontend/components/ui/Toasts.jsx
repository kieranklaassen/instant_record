import { useCallback, useRef, useState } from "react"
import Icon from "./Icon"
import Kbd from "./Kbd"

// useNotices() answers { notices, notify, dismiss }: short messages that
// leave by themselves. Saying the same thing twice shows it once.
export function useNotices({ ms = 6000 } = {}) {
  const [notices, setNotices] = useState([])
  const next = useRef(1)

  const dismiss = useCallback((key) => setNotices((notices) => notices.filter((notice) => notice.key !== key)), [])

  const notify = useCallback((text) => {
    const key = next.current++
    setNotices((notices) => [...notices.filter((notice) => notice.text !== text), { key, text }])
    setTimeout(() => dismiss(key), ms)
  }, [dismiss, ms])

  return { notices, notify, dismiss }
}

// The page's toasts, bottom centre: what went wrong, and the newest action
// that can still be undone. The stack is a polite live region, so each toast
// is also spoken.
//
//   notices   from useNotices
//   pending   from useUndoable: the actions that can be undone, newest last
//   undoKey   the chord that undoes, for the cap on the button
export default function Toasts({ notices, pending, undoKey, onUndo, onDismiss }) {
  const action = pending.at(-1)
  return (
    <div className="ui-toasts" role="status" aria-live="polite">
      {notices.map((notice) => (
        <div className="ui-toast" data-kind="notice" key={notice.key}>
          <span>{notice.text}</span>
          <button type="button" className="ui-toast-close" aria-label="Dismiss" onClick={() => onDismiss(notice.key)}>
            <Icon name="close" size={14} />
          </button>
        </div>
      ))}
      {action && (
        <div className="ui-toast" data-kind="undo" key={action.key}>
          <span>{action.label}{pending.length > 1 && <small> · {pending.length - 1} more</small>}</span>
          <button type="button" className="ui-toast-undo" onClick={onUndo}>
            <Icon name="undo" size={14} /> Undo {undoKey && <Kbd chord={undoKey} tone="on-ink" />}
          </button>
        </div>
      )}
    </div>
  )
}
