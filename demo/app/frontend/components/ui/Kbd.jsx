import { keycaps } from "instant_record"

// The key caps of one chord ("Mod+Enter" draws ⌘ ↵ on a Mac, Ctrl ↵ elsewhere).
//
//   <Kbd chord="e" />
//   <Kbd chord="Mod+Shift+Enter" tone="on-accent" />
export default function Kbd({ chord, tone }) {
  return (
    <span className="ui-keys" data-tone={tone}>
      {keycaps(chord).map((cap, index) => <kbd key={index}>{cap}</kbd>)}
    </span>
  )
}
