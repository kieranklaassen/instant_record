// Canonical manifest reader shared by the browser worker and page harness.
// Fed from `instant_record.manifest.json` via VITE_MANIFEST at build time.

export function normalizePath(pathname) {
  let cleaned = String(pathname || "/").trim().replace(/\/+/g, "/");
  if (!cleaned.startsWith("/")) cleaned = `/${cleaned}`;
  return cleaned.length > 1 ? cleaned.replace(/\/+$/, "") : cleaned || "/";
}

export function routePatternToRegex(pattern) {
  const normalized = normalizePath(pattern).replace(/\([^)]*\)/g, "");
  if (normalized === "/") return /^\/$/;

  const segments = normalized.slice(1).split("/").filter(Boolean).map((segment) => {
    if (segment.startsWith("*")) return ".+";
    if (segment.startsWith(":")) return "[^/]+";
    return segment
      .replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
      .replace(/:[a-zA-Z_]\w*/g, "[^/]+");
  });
  return new RegExp(`^/${segments.join("/")}/?$`);
}

function compileRoutes(routes) {
  return (Array.isArray(routes) ? routes : [])
    .filter((route) => route && route.path)
    .map((route) => ({
      method: String(route.method || "GET").toUpperCase(),
      path: normalizePath(route.path),
      controller: route.controller || null,
      action: route.action || null,
      regex: routePatternToRegex(route.path),
    }));
}

export function parseManifest(raw) {
  let data = {};
  if (typeof raw === "string" && raw.trim()) {
    try {
      data = JSON.parse(raw);
    } catch {
      data = {};
    }
  } else if (raw && typeof raw === "object") {
    data = raw;
  }

  return {
    schemaVersion: data.schema_version ?? 1,
    mode: data.mode === "island" ? "island" : "full",
    island: data.island ?? null,
    models: Array.isArray(data.models) ? data.models : [],
    localRoutes: compileRoutes(data.local_routes),
    serverRoutes: compileRoutes(data.server_routes),
  };
}

export function matchesRoute(compiledRoutes, method, pathname) {
  const verb = String(method || "GET").toUpperCase();
  const normalized = normalizePath(pathname);
  return compiledRoutes.some((route) => route.method === verb && route.regex.test(normalized));
}

export function matchesAnyPath(compiledRoutes, pathname) {
  const normalized = normalizePath(pathname);
  return compiledRoutes.some((route) => route.regex.test(normalized));
}

function syncBasePath(syncEndpoint = "/instant_record") {
  try {
    return normalizePath(new URL(syncEndpoint, "http://instant-record.local").pathname);
  } catch {
    return normalizePath(syncEndpoint);
  }
}

function isLocalSyncNotices(pathname, syncEndpoint = "/instant_record") {
  const normalized = normalizePath(pathname);
  const noticesBase = `${syncBasePath(syncEndpoint)}/sync_notices`;
  return normalized === noticesBase || normalized === `${noticesBase}.json` || normalized.startsWith(`${noticesBase}/`);
}

// Match a request against the island's local_routes.
// When `method` is provided:
// - GET/HEAD match GET routes.
// - POST matches POST, PATCH, PUT, or DELETE routes (Rails forms tunnel
//   PATCH/PUT/DELETE over POST with a `_method` parameter).
// - Explicit PATCH/PUT/DELETE match their exact HTTP verb.
export function isLocalRoute(manifest, pathname, method = null, syncEndpoint = "/instant_record") {
  if (!manifest || manifest.mode !== "island" || manifest.localRoutes.length === 0) return true;
  if (isLocalSyncNotices(pathname, syncEndpoint)) return true;
  if (!method) return matchesAnyPath(manifest.localRoutes, pathname);

  const verb = String(method).toUpperCase();
  if (verb === "HEAD") return matchesRoute(manifest.localRoutes, "GET", pathname);
  if (verb === "POST") {
    return ["POST", "PATCH", "PUT", "DELETE"].some((v) => matchesRoute(manifest.localRoutes, v, pathname));
  }
  return matchesRoute(manifest.localRoutes, verb, pathname);
}

export function isServerAllowed(manifest, method, pathname, syncEndpoint = "/instant_record") {
  const verb = String(method || "GET").toUpperCase();
  const normalized = normalizePath(pathname);
  const syncBase = syncBasePath(syncEndpoint);

  if (verb === "GET" && normalized === `${syncBase}/bootstrap`) return true;
  if (verb === "POST" && normalized === `${syncBase}/mutations`) return true;

  if (!manifest || !Array.isArray(manifest.serverRoutes)) return false;
  return matchesRoute(manifest.serverRoutes, verb, normalized);
}
