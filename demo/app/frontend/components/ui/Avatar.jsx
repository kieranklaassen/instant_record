// A person as an initial in a circle. The class carries the name, so a
// stylesheet can give a known person a colour of their own (`.avatar-maya`).
export default function Avatar({ name, tinted = true, size }) {
  const who = name.toLowerCase().replace(/[^a-z]/g, "")
  return (
    <span className={`ui-avatar${tinted && who ? ` avatar-${who}` : ""}`} data-size={size} aria-hidden="true">
      {(name[0] || "?").toUpperCase()}
    </span>
  )
}
