// Copy-on-write local SQLite staging branch coordinator for the browser worker.
//
// Forks the live `main` SQLite file bytes into an isolated offline AppHost so
// users or AI agents can execute bulk actions, inspect the resulting state
// rendered through the real Rails UI, and then either:
//   - approve: extract ONLY the new branch OutboxMutations and replay them onto
//     current `main` (preserving remote deltas that arrived during review), or
//   - discard: drop the cloned SQLite instance with zero `main` or server impact.

function generateBranchId() {
  if (globalThis.crypto?.randomUUID) return globalThis.crypto.randomUUID();
  return "branch-" + Math.random().toString(36).slice(2, 10);
}

function normalizeName(name) {
  const cleaned = typeof name === "string" ? name.trim() : "";
  return cleaned || "staging";
}

export class BranchManager {
  constructor() {
    this.active = null;
  }

  isActive() {
    return this.active !== null;
  }

  host() {
    return this.active ? this.active.host : null;
  }

  // Clone the live `main` SQLite bytes into a fresh isolated staging host.
  fork({ name = "staging", mainHost, createHost, schemaVersion = 0 }) {
    if (this.active) {
      throw new Error(`Already on staging branch '${this.active.name}' — approve or discard it first`);
    }
    if (!mainHost) {
      throw new Error("Cannot create a staging branch before the app has booted");
    }

    const bytes = mainHost.cloneDatabaseBytes
      ? mainHost.cloneDatabaseBytes()
      : (() => {
          const raw = mainHost.databaseBytes();
          return raw ? new Uint8Array(raw) : null;
        })();
    if (!bytes) {
      throw new Error("SQLite has not produced a database snapshot yet");
    }

    const baseOutbox = mainHost.branchOutbox([]);
    const baseOutboxIds = (baseOutbox.mutations || []).map((mutation) => String(mutation.id));
    const branchName = normalizeName(name);
    const branchHost = createHost(bytes, schemaVersion, branchName);
    branchHost.ensureBooted();

    this.active = {
      id: generateBranchId(),
      name: branchName,
      createdAt: Date.now(),
      host: branchHost,
      baseOutboxIds,
      mainDeltasDuringReview: 0,
    };

    return this.inspect();
  }

  // Record that `main` received remote deltas while this branch was open.
  noteMainDelta(count = 1) {
    if (!this.active) return null;
    this.active.mainDeltasDuringReview += Math.max(1, Number(count) || 1);
    return this.inspect();
  }

  // Current preview status + staged OutboxMutation diff.
  inspect() {
    if (!this.active) return { active: false };

    const summary = this.active.host.branchOutbox(this.active.baseOutboxIds);
    return {
      active: true,
      id: this.active.id,
      name: this.active.name,
      createdAt: this.active.createdAt,
      stagedCount: summary.count || 0,
      byOperation: summary.by_operation || {},
      byType: summary.by_type || {},
      mutations: summary.mutations || [],
      mainDeltasDuringReview: this.active.mainDeltasDuringReview,
    };
  }

  // Extract ONLY branch mutations and replay them onto current `main` via `onMain`.
  async approve({ conflict = "lww", onMain }) {
    if (!this.active) {
      throw new Error("No active staging branch to approve");
    }

    const branch = this.active;
    const summary = branch.host.branchOutbox(branch.baseOutboxIds);
    const mutations = summary.mutations || [];

    const replay = await onMain(mutations, conflict);
    this.active = null;

    return {
      approved: true,
      id: branch.id,
      name: branch.name,
      mutationsCount: mutations.length,
      applied: replay.applied || 0,
      skipped: replay.skipped || 0,
      conflicts: replay.conflicts || [],
      changes: replay.changes || null,
      mainDeltasDuringReview: branch.mainDeltasDuringReview,
    };
  }

  // Drop the staging branch with zero writes to `main` and zero server impact.
  discard() {
    if (!this.active) {
      throw new Error("No active staging branch to discard");
    }

    const branch = this.active;
    const summary = branch.host.branchOutbox(branch.baseOutboxIds);
    const dropped = summary.count || 0;
    this.active = null;

    return {
      discarded: true,
      id: branch.id,
      name: branch.name,
      dropped,
      mainDeltasDuringReview: branch.mainDeltasDuringReview,
    };
  }
}
