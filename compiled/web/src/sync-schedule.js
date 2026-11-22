// Decides how the worker schedules its next sync pass from local outbox state:
// matured pending writes or an unbootstrapped DB drain immediately (or with
// retry backoff), held writes wait cleanly until their earliest release_at
// without blocking inbound polls, and an empty outbox clears any held timer.
export function nextSyncAction({ pending = 0, bootstrapped = true, nextReleaseMs = null } = {}, immediateDelay = 0) {
  if (pending > 0 || !bootstrapped) return { kind: "immediate", delay: immediateDelay };
  if (nextReleaseMs != null) return { kind: "held", delay: Math.max(0, nextReleaseMs) };
  return { kind: "idle" };
}
