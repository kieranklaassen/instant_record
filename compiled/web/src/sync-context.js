// Declarative partition context resolution for the compiled browser runtime.
// Apps declare partitioned routes via VITE_SYNC_PARTITIONS (JSON array of rules),
// keeping worker.js and main.js free of app-specific URL or endpoint logic.
//
// Each rule may specify:
//   path             pathname prefix/match (e.g. "/email")
//   partitionParam   query param carrying the partition value (e.g. "inbox")
//   partitionDefault default partition value when omitted
//   partitionKey     optional column/name prefix for X-Instant-Record-Partition (e.g. "mailbox_id")
//   scopeParam       optional secondary query param (e.g. "member")
//   scopeDefault     optional default for scopeParam
//   scopeHeader      optional header name for scopeParam (e.g. "X-Instant-Record-Member")
//   valid            optional regex string validating extracted values
//   lookupParams     optional query params whose values should be pre-fetched via /records?id=
//   preloadBefore    optional { idParam, atParam, type, limit } for deep-link page preloading
//   shellPath        optional path for prebuilt SQLite shell endpoint

export function parseRules(raw) {
  if (Array.isArray(raw)) return raw;
  if (typeof raw !== "string" || !raw.trim()) return [];
  try {
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

export function resolveSyncContext(path, rules = parseRules(import.meta.env?.VITE_SYNC_PARTITIONS)) {
  if (!rules.length) return null;
  const url = new URL(path || "/", "https://sync-context.invalid");
  const pathname = url.pathname.replace(/\/$/, "") || "/";
  const rule = rules.find(entry => (entry.path || "").replace(/\/$/, "") === pathname);
  if (!rule) return null;

  const partitionValue = url.searchParams.get(rule.partitionParam) || rule.partitionDefault || "";
  const scopeValue = rule.scopeParam ? (url.searchParams.get(rule.scopeParam) || rule.scopeDefault || "") : "";
  const validator = rule.valid ? new RegExp(rule.valid) : null;
  const checked = rule.scopeParam ? [scopeValue, partitionValue] : [partitionValue];
  const valid = checked.every(value => value && (!validator || validator.test(value)));

  if (!valid) {
    return {
      valid: false,
      storageKey: "invalid",
      partition: "",
      partitionValue: "",
      scopeValue: "",
      headers: {},
      lookupIds: [],
      preloadBefore: null,
      shellPath: null,
    };
  }

  const partition = rule.partitionKey ? `${rule.partitionKey}:${partitionValue}` : partitionValue;
  const storageKey = scopeValue ? `${scopeValue}/${partitionValue}` : partitionValue;
  const headers = { "X-Instant-Record-Partition": partition };
  if (rule.scopeHeader && scopeValue) headers[rule.scopeHeader] = scopeValue;

  const lookupIds = [...new Set(
    (Array.isArray(rule.lookupParams) ? rule.lookupParams : [])
      .map(name => url.searchParams.get(name))
      .filter(Boolean)
  )];

  let preloadBefore = null;
  if (rule.preloadBefore) {
    const id = url.searchParams.get(rule.preloadBefore.idParam);
    const at = url.searchParams.get(rule.preloadBefore.atParam);
    if (id && at) {
      preloadBefore = {
        type: rule.preloadBefore.type,
        before: { id, created_at: at },
        limit: rule.preloadBefore.limit || 50,
      };
    }
  }

  return {
    valid: true,
    storageKey,
    partition,
    partitionValue,
    scopeValue,
    headers,
    lookupIds,
    preloadBefore,
    shellPath: rule.shellPath || null,
  };
}
