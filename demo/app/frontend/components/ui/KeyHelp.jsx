import { useEffect, useRef } from "react"
import Kbd from "./Kbd"

// The list of keys, drawn from the same bindings that run them.
//
//   bindings  [{ group, label, keys }]
//   groups    the group names, in the order to show them
//
// A modal dialog: it takes focus, Escape or a click outside closes it, and
// focus goes back to where it was.
export default function KeyHelp({ bindings, groups, onClose }) {
  const card = useRef(null)

  useEffect(() => {
    const before = document.activeElement
    card.current?.focus()
    return () => before?.focus?.()
  }, [])

  const key = (event) => {
    if (event.key !== "Escape") return
    event.preventDefault()
    onClose()
  }

  return (
    <div className="ui-help" onClick={onClose}>
      <div className="ui-help-card" role="dialog" aria-modal="true" aria-labelledby="ui-help-title" tabIndex={-1}
        ref={card} onKeyDown={key} onClick={(event) => event.stopPropagation()}>
        <h2 id="ui-help-title">Keyboard shortcuts</h2>
        <div className="ui-help-groups">
          {groups.map((group) => (
            <section key={group}>
              <h3>{group}</h3>
              <dl>
                {bindings.filter((binding) => binding.group === group).map((binding) => (
                  <div key={binding.id}>
                    <dd>{binding.label}</dd>
                    <dt>
                      {binding.keys.map((chord, index) => (
                        <span key={chord}>{index > 0 && <i>or</i>}<Kbd chord={chord} /></span>
                      ))}
                    </dt>
                  </div>
                ))}
              </dl>
            </section>
          ))}
        </div>
        <p className="ui-help-foot">Press <Kbd chord="?" /> or <Kbd chord="Escape" /> to close</p>
      </div>
    </div>
  )
}
