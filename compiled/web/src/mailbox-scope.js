// Only the demo build enables the fictional persona picker. Consumers keep
// their configured endpoint and their existing snapshot name.
export function mailboxScope(path, sharedInbox = Boolean(import.meta.env?.VITE_SHARED_INBOX_DEMO)) {
  const url = new URL(path, "https://demo.invalid")
  if (!sharedInbox || url.pathname.replace(/\/$/, "") !== "/email") return ""
  const member = url.searchParams.get("member") || "maya"
  const inbox = url.searchParams.get("inbox") || "support"
  if (![member, inbox].every(value => /^[a-z]{1,32}$/.test(value))) return "invalid/invalid"
  return member + "/" + inbox
}
