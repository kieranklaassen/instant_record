// Outbox-preserving schema drift detection and auto-rehydration for the
// compiled browser worker. Replaces fatal boot/snapshot errors with:
//   1. Extract pending instant_record_outbox rows from the drifted SQLite image
//   2. Boot a clean SQLite database on the target release's schema
//   3. Re-insert preserved outbox rows atomically
//   4. Trigger a normal outbox drain + re-bootstrap from the server

export function detectSchemaDrift({
  bytes,
  version,
  targetSchema,
  legacySchema,
  history,
  migrationHistory,
  previousDigest,
  schemaDigest,
}) {
  if (bytes && version == null && !legacySchema) {
    return "unversioned_snapshot";
  }
  const previous = version ?? Number(legacySchema);
  if (bytes && previous > targetSchema) {
    return `schema_version_ahead:${previous}`;
  }
  if (bytes && legacySchema && previous < Number(legacySchema)) {
    return `schema_version_below_baseline:${previous}`;
  }
  if (history) {
    const priorVersions = new Set([...Object.keys(history), ...Object.keys(migrationHistory || {})]);
    for (const key of priorVersions) {
      if (Number(key) <= previous && migrationHistory?.[key] !== history[key]) {
        return `published_migration_changed:${key}`;
      }
    }
  }
  if (version === targetSchema && previousDigest && previousDigest !== schemaDigest) {
    return "schema_digest_mismatch";
  }
  if (bytes && previous < targetSchema && !(targetSchema in (migrationHistory || {}))) {
    return `missing_browser_migration:${targetSchema}`;
  }
  return null;
}

export function rehydrateFromBytes({ bytes, reason, createHost, onReport }) {
  const started = performance.now();
  let extracted = [];
  let extractFailed = false;

  if (bytes && bytes.length > 0) {
    try {
      const extractor = createHost();
      extracted = extractor.extractOutbox(bytes);
    } catch {
      extractFailed = true;
      extracted = [];
    }
  }

  const fresh = createHost();
  const initStart = performance.now();
  fresh.ensureBooted();
  if (extracted.length > 0) {
    fresh.importOutbox(extracted);
  }
  const runtimeMs = performance.now() - initStart;
  const status = extractFailed
    ? "extract_failed; clean rebuild"
    : `${extracted.length} outbox preserved`;

  onReport?.({
    kind: "schema",
    method: "REHYDRATE",
    path: reason,
    status,
    ms: Math.round(performance.now() - started),
  });

  return {
    host: fresh,
    restored: false,
    fromShell: false,
    runtimeMs,
    rehydrated: {
      reason,
      preservedOutbox: extracted.length,
      extractFailed,
    },
  };
}

export function openOrRehydrate({
  bytes,
  version,
  targetSchema,
  legacySchema,
  history,
  migrationHistory,
  previousDigest,
  schemaDigest,
  shell,
  createHost,
  onReport,
}) {
  const drift = detectSchemaDrift({
    bytes,
    version,
    targetSchema,
    legacySchema,
    history,
    migrationHistory,
    previousDigest,
    schemaDigest,
  });

  if (drift) {
    return rehydrateFromBytes({ bytes, reason: drift, createHost, onReport });
  }

  const previous = version ?? Number(legacySchema);
  const candidate = createHost();
  const fromShell = !bytes && !!shell;
  if (bytes) candidate.restoreDatabase(bytes, previous);
  if (fromShell) candidate.restoreDatabase(shell.bytes, targetSchema);

  const initStart = performance.now();
  try {
    candidate.ensureBooted();
  } catch (error) {
    if (bytes) {
      return rehydrateFromBytes({
        bytes,
        reason: "migration_failed",
        createHost,
        onReport,
      });
    }
    throw error;
  }

  return {
    host: candidate,
    restored: !!bytes,
    fromShell,
    runtimeMs: performance.now() - initStart,
    rehydrated: null,
  };
}

export function reloadOrRehydrateSnapshot({
  bytes,
  savedSchema,
  targetSchema,
  createHost,
  onReleaseRequired,
  onReport,
}) {
  if (savedSchema !== targetSchema) {
    const peerAhead = savedSchema != null && savedSchema > targetSchema;
    if (peerAhead) onReleaseRequired?.();
    const outcome = rehydrateFromBytes({
      bytes,
      reason: peerAhead
        ? `peer_schema_ahead:${savedSchema}`
        : `snapshot_schema_mismatch:${savedSchema}`,
      createHost,
      onReport,
    });
    return {
      ...outcome,
      persist: !peerAhead,
      needsBootstrap: true,
    };
  }

  const restored = createHost();
  if (bytes) restored.restoreDatabase(bytes, targetSchema);
  try {
    restored.ensureBooted();
  } catch (error) {
    if (bytes) {
      const outcome = rehydrateFromBytes({
        bytes,
        reason: "snapshot_boot_failed",
        createHost,
        onReport,
      });
      return {
        ...outcome,
        persist: true,
        needsBootstrap: true,
      };
    }
    throw error;
  }

  return {
    host: restored,
    rehydrated: null,
    persist: false,
    needsBootstrap: false,
  };
}
