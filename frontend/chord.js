// Naming a key press, and finding the binding for it. No React here, so the
// tests import this file alone.
//
// A chord is a string: "j", "Shift+J", "Mod+Enter", "Mod+Shift+Enter", "?",
// "Escape", "Space". `Mod` is ⌘ on Apple platforms and Ctrl everywhere else.
//
// A binding is { keys, run, label, group, when, typing, dialog, repeat }:
//
//   keys    the chords that run it
//   when    () => false where it does not apply just now
//   typing  true for a binding that also runs while a text field has focus
//   dialog  true for a binding that also runs inside an open dialog
//   repeat  true for a binding a held key repeats (movement)
//
// `label` and `group` are for whoever lists the keys: the same table drives
// the handlers and the help, so the two cannot disagree.

export const isApple = () =>
  typeof navigator !== "undefined" && /Mac|iPhone|iPad|iPod/.test(navigator.platform || navigator.userAgent || "")

const isLetter = (key) => key.length === 1 && key.toLowerCase() !== key.toUpperCase()

// The chord an event is, or null for one no binding can name (Alt, or the
// other platform's modifier).
export function chord(event, { apple = isApple() } = {}) {
  // Autofill sends a keydown with no key.
  if (event.altKey || !event.key) return null
  const mod = apple ? event.metaKey : event.ctrlKey
  if (apple ? event.ctrlKey : event.metaKey) return null

  const key = event.key === " " ? "Space" : event.key
  const letter = isLetter(key)
  // A shifted symbol is its own name: "?" and never "Shift+/".
  const shift = event.shiftKey && (letter || key.length > 1)
  const name = letter ? (shift ? key.toUpperCase() : key.toLowerCase()) : key
  return [mod && "Mod", shift && "Shift", name].filter(Boolean).join("+")
}

// What kind of place a key press landed in.
export function place(target) {
  if (!target?.tagName) return {}
  const tag = target.tagName
  const pressable = tag === "INPUT" && /^(checkbox|radio|button|submit|reset)$/.test(target.type || "")
  return {
    typing: !pressable && (!!target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(tag)),
    control: pressable || /^(BUTTON|A|SUMMARY)$/.test(tag),
    dialog: !!target.closest?.("[role=dialog]"),
  }
}

const ACTIVATES = /(^|\+)(Enter|Space)$/

// The first binding that answers this event where it landed, or null.
export function match(bindings, event, target, options) {
  const name = chord(event, options)
  if (!name) return null
  const at = place(target)
  return bindings.find((binding) => {
    if (!binding.keys.includes(name)) return false
    if (event.repeat && !binding.repeat) return false
    if (at.typing && !binding.typing) return false
    if (at.dialog && !binding.dialog) return false
    // A button, link or checkbox keeps the keys that press it.
    if (at.control && ACTIVATES.test(name)) return false
    return !binding.when || binding.when()
  }) || null
}

const CAPS = { Escape: "Esc", Enter: "↵", ArrowDown: "↓", ArrowUp: "↑", ArrowLeft: "←", ArrowRight: "→" }

// The key caps to draw for a chord: "Mod+Shift+Enter" is ["⌘", "⇧", "↵"] on a
// Mac and ["Ctrl", "Shift", "↵"] elsewhere.
export function keycaps(name, { apple = isApple() } = {}) {
  return name.split("+").map((part) => {
    if (part === "Mod") return apple ? "⌘" : "Ctrl"
    if (part === "Shift") return apple ? "⇧" : "Shift"
    return CAPS[part] || (part.length === 1 ? part.toUpperCase() : part)
  })
}
