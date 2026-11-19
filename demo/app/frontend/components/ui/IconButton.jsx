import Icon from "./Icon"
import Kbd from "./Kbd"

// A button that shows its key. `chord` is the binding's first key, so the cap
// on the control and the key that works come from the same table.
//
//   <IconButton icon="archive" chord="e" onClick={archive}>Archive</IconButton>
export default function IconButton({ icon, chord, tone, quiet = true, className = "", children, ...button }) {
  return (
    <button type="button" className={`ui-button ${className}`} data-quiet={String(quiet)} {...button}>
      {icon && <Icon name={icon} size={15} />}
      <span>{children}</span>
      {chord && <Kbd chord={chord} tone={tone} silent />}
    </button>
  )
}
