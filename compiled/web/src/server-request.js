// Pure routing helpers shared between main.js and worker.js so consumer apps
// can use custom mount paths, InstantRecord.server_url, and service workers.

const trimTrailingSlash = (value) => String(value || "").replace(/\/+$/, "");

// Derive the Rails app root from the configured sync endpoint and mount path.
// Examples:
//   ("/instant_record", "/instant_record")            -> ""
//   ("/sync", "/sync")                                -> ""
//   ("http://localhost:3000/sync", "/sync")           -> "http://localhost:3000"
//   ("http://localhost:3000/api/sync", "/sync")       -> "http://localhost:3000/api"
export function serverRoot(publicEndpoint, mountPath = "/instant_record") {
  const endpoint = trimTrailingSlash(publicEndpoint);
  const mount = trimTrailingSlash(mountPath || "/instant_record");
  if (mount && endpoint.endsWith(mount)) {
    return endpoint.slice(0, endpoint.length - mount.length);
  }
  if (/^https?:\/\//i.test(endpoint)) {
    return new URL(endpoint).origin;
  }
  return "";
}

// Validate a page-initiated serverRequest path and strip the network marker.
// Rejects protocol-relative or cross-origin paths.
export function resolveServerRequest(path, origin) {
  if (typeof path !== "string" || !path.startsWith("/") || path.startsWith("//") || path.includes("\\")) {
    throw new Error("Invalid server request path");
  }
  const baseOrigin = new URL(origin).origin;
  const url = new URL(path, baseOrigin);
  if (url.origin !== baseOrigin || !url.pathname.startsWith("/") || url.pathname.startsWith("//")) {
    throw new Error("Invalid server request path");
  }
  url.searchParams.delete("instant_record_network");
  return url.pathname + url.search;
}

// Decide whether a browser fetch should be answered by the local Wasm app
// instead of passing through to the network.
export function isLocalUrl(url, origin, syncEndpoint = "/instant_record") {
  if (url.origin !== origin) return false;
  const pathname = url.pathname;
  if (
    pathname === "/service-worker.js" ||
    pathname === "/instant-record-release.json" ||
    pathname === "/instant_record.manifest.json" ||
    pathname.startsWith("/assets/") ||
    pathname.startsWith("/harness/") ||
    /^\/app[-.\w]*\.wasm$/.test(pathname)
  ) {
    return false;
  }
  if (syncEndpoint) {
    const syncUrl = new URL(syncEndpoint, origin);
    const syncBase = trimTrailingSlash(syncUrl.pathname);
    if (syncUrl.origin === origin && syncBase && (pathname === syncBase || pathname.startsWith(syncBase + "/"))) {
      // Quarantined sync notices live in this browser's local SQLite ledger,
      // so Hotwire form posts and reads under /<mount>/sync_notices stay local.
      const noticesBase = syncBase + "/sync_notices";
      if (pathname === noticesBase || pathname === noticesBase + ".json" || pathname.startsWith(noticesBase + "/")) {
        return true;
      }
      return false;
    }
  }
  return true;
}
