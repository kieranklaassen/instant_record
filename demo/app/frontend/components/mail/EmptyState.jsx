import Icon from "../ui/Icon"

export default function EmptyState() {
  return (
    <div className="mail-empty">
      <span className="mail-mark" aria-hidden="true"><Icon name="check" size={18} /></span>
      <h2>Your inbox is clear</h2>
      <p>Generate an incoming email to start a conversation.</p>
    </div>
  )
}
