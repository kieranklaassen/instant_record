// Cold-start SQLite shell helpers shared by worker.js and unit tests.

export const SQLITE_MAGIC = "SQLite format 3\0";

export function scopedUrl(url, syncScope) {
  if (!syncScope) return url;
  return url + (url.includes("?") ? "&" : "?") + "scope=" + encodeURIComponent(syncScope);
}

// A shell is fetched for any compiled app when a build enables shell snapshots
// (VITE_SHELL_SNAPSHOT=1) or the page opts in with ?shell=1.
export function shouldFetchShell({ path, fingerprint, always, offline, blocked = false }) {
  if (blocked || offline || !fingerprint) return false;
  if (always) return true;
  try {
    const url = new URL(path || "/", "https://instant-record.invalid");
    return url.searchParams.get("shell") === "1";
  } catch {
    return false;
  }
}

export function parseShellGrant(text) {
  try {
    const parsed = JSON.parse(text);
    if (!parsed || typeof parsed !== "object") return null;
    const { path, cursor, identity } = parsed;
    if (typeof path !== "string" || !path.startsWith("/shell/file")) return null;
    if (!Number.isInteger(cursor) || cursor < 0) return null;
    return { path, cursor, identity: typeof identity === "string" ? identity : "" };
  } catch {
    return null;
  }
}

export function isValidSqliteBytes(bytes) {
  if (!(bytes instanceof Uint8Array) || bytes.length < SQLITE_MAGIC.length) return false;
  return new TextDecoder().decode(bytes.subarray(0, SQLITE_MAGIC.length)) === SQLITE_MAGIC;
}

export function validateShellState(state, grant) {
  if (!state || !grant) return false;
  if (!state.bootstrapped || state.cursor !== grant.cursor) return false;
  if (grant.identity && state.identity !== grant.identity) return false;
  return true;
}
