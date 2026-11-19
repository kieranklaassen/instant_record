import { keycaps } from "instant_record"

// The key caps of one chord ("Mod+Enter" draws ⌘ ↵ on a Mac, Ctrl ↵ elsewhere).
//
//   <Kbd chord="e" />
//   <Kbd chord="Mod+Shift+Enter" tone="on-accent" />
//
// `silent` keeps the caps out of a control's name: a button reads "Archive",
// not "Archive E".
export default function Kbd({ chord, tone, silent = false }) {
  return (
    <span className="ui-keys" data-tone={tone} aria-hidden={silent || undefined}>
      {keycaps(chord).map((cap, index) => <kbd key={index}>{cap}</kbd>)}
    </span>
  )
}
