// Non-livelocking bounded outbox drain coordinator for the dedicated worker.
//
// Sends one bounded batch from syncPlan() outside IndexedDB locks, then merges
// the completed response into whatever is now in SQLite by mutation_id — never
// discarding completed acks when newer local edits or peer-tab writes landed
// while the network request was in flight.
export async function runDrain({
  withSnapshot,
  fetchReply,
  getHost,
  syncEndpoint,
  initial = false,
  early = null,
  report = () => {},
  setCursor = () => {},
  onRecordsChanged = () => {},
  onSyncNotices = () => {},
  scheduleRetry,
  scheduleHeld = () => {},
  onIdle = () => {},
  retryState,
}) {
  const plan = await withSnapshot("readonly", () => getHost().syncPlan());
  if (!plan.push && !plan.bootstrap) {
    retryState.delayMs = retryState.baseMs;
    const nextReleaseMs = plan.next_release_ms ?? null;
    if (nextReleaseMs != null) scheduleHeld(Math.max(0, nextReleaseMs));
    else onIdle();
    return { changed: false, notified: false, pending: 0, nextReleaseMs };
  }
  const push = plan.push ? await fetchReply("POST", "/mutations", plan.push) : null;
  const snapshot = plan.bootstrap ? (early?.status === 200 ? early : await fetchReply("GET", "/bootstrap")) : null;

  const result = await withSnapshot("readwrite", save => {
    const host = getHost();
    const preparedPush = push
      ? { status: push.status, body: push.text, mutation_ids: plan.mutation_ids || [] }
      : null;
    const preparedBootstrap = snapshot
      ? { status: snapshot.status, body: snapshot.text }
      : null;

    const applied = host.applySync(syncEndpoint, {
      push: preparedPush,
      bootstrap: preparedBootstrap,
    });
    const needsBootstrap = plan.bootstrap && !host.syncState().bootstrapped;
    if (push || snapshot) report({ kind: "sync-pass", path: `${applied.pending} pending` });
    // After a bootstrap the next poll reads the cursor and the identity afresh.
    setCursor(plan.bootstrap ? null : applied.cursor);
    const syncNotices = applied.notices?.length && typeof host.notices === "function"
      ? host.notices({ action: "list" }).notices
      : null;
    if (applied.changed || applied.notified) {
      save();
    }

    if (applied.pending > 0 || needsBootstrap) {
      if (!applied.failed && (applied.progressed || (!push && !snapshot))) {
        retryState.delayMs = retryState.baseMs;
        scheduleRetry(0);
      } else {
        scheduleRetry(retryState.delayMs);
        retryState.delayMs = Math.min(retryState.delayMs * 2, retryState.capMs);
      }
    } else if (applied.nextReleaseMs != null) {
      retryState.delayMs = retryState.baseMs;
      scheduleHeld(Math.max(0, applied.nextReleaseMs));
    } else {
      retryState.delayMs = retryState.baseMs;
      onIdle();
    }
    return { ...applied, syncNotices };
  });

  if (result.syncNotices) onSyncNotices(result.syncNotices);
  if (!initial && result.notified) onRecordsChanged(result.changes);
  return result;
}
