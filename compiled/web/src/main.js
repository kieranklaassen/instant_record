import { mailboxScope } from "./mailbox-scope.js";
import { watchRelease } from "./release-updates.js";
import { isLocalUrl } from "./server-request.js";
let releaseRequired;
const worker = new Worker(new URL("./worker.js", import.meta.url), { type: "module" });
const waiting = new Map();
let nextId = 1;
let historyFill = null;
worker.onmessage = (event) => {
  const { id, result, error, type } = event.data;
  if (type === "release_required") return releaseRequired?.();
  if (type === "storage_upgrade_blocked") {
    document.body.textContent = "Close or reload other tabs running the previous version of this app. Your saved changes will be kept.";
    return;
  }
  if (type === "instant_record.history") {
    // How much of the model's history the local database holds: { done, full, rows }.
    historyFill = event.data.state;
    if (window.__spinel) window.__spinel.history = historyFill;
    window.dispatchEvent(new CustomEvent("instant-record:history", { detail: historyFill }));
    return;
  }
  if (type === "records_changed") {
    if (marks.rendered) recordsChanged(event.data.changes);
    return;
  }
  const entry = waiting.get(id);
  if (!entry) return;
  waiting.delete(id);
  error ? entry.reject(new Error(error)) : entry.resolve(result);
};
const call = (type, payload) => new Promise((resolve, reject) => {
  const id = nextId++;
  waiting.set(id, { resolve, reject });
  worker.postMessage({ id, type, payload });
});

const initialScope = mailboxScope(location.href);
const marks = { start: performance.now() };
// Where the sync server is and who this browser is to it, for a page that asks it for
// something itself: the bytes of a record that declares sync_file (frontend/files.js).
const syncEndpoint = import.meta.env.VITE_SYNC_ENDPOINT || "/instant_record";
window.__spinel = { marks, call, worker, history: historyFill, sourceVersion: import.meta.env.VITE_SOURCE_VERSION,
  endpoint: syncEndpoint, scope: syncScope() };

// Restore the switches before even the first bootstrap can reach Rails.
try {
  const ui = JSON.parse(sessionStorage.getItem("instant_record.inspector"));
  if (ui) worker.postMessage({
    type: "instant_record.simulate",
    settings: { offline: !!ui.offline, latencyMs: ui.slow ? 2000 : 0 },
  });
} catch { /* Storage may be unavailable. */ }

// Static assets, service worker, release manifest, and same-origin sync/file
// endpoints go straight to the network rather than the in-worker Wasm app.
const isLocal = (url) => isLocalUrl(url, location.origin, syncEndpoint);

// One page request; the worker follows the app's redirects and returns the final answer.
const appRequest = (method, path, body, contentType) => call("navigate", { method, path, body, contentType });

const encodeFormData = (form) => {
  const fields = new URLSearchParams();
  for (const [name, value] of form.entries()) if (typeof value === "string") fields.append(name, value);
  return fields.toString();
};

const headerValue = (headers, target) => {
  if (!headers) return undefined;
  if (headers instanceof Headers) return headers.get(target) || undefined;
  const lower = target.toLowerCase();
  if (Array.isArray(headers)) {
    const pair = headers.find(([k]) => k.toLowerCase() === lower);
    return pair?.[1];
  }
  for (const [k, v] of Object.entries(headers)) if (k.toLowerCase() === lower) return v;
  return undefined;
};

// The same seam a service worker's fetch handler is, from inside the page.
const networkFetch = window.fetch.bind(window);
window.fetch = async (input, init) => {
  const isUrlInput = typeof input === "string" || input instanceof URL;
  const url = isUrlInput ? new URL(input, location.href) : new URL(input.url);
  if (url.origin === location.origin && url.searchParams.has("instant_record_network")) {
    const method = (isUrlInput ? init?.method : init?.method || input.method) || "GET";
    const contentType = isUrlInput
      ? headerValue(init?.headers, "content-type")
      : (init?.headers ? headerValue(init.headers, "content-type") : input.headers.get("content-type") || undefined);
    const body = isUrlInput ? init?.body : (init?.body ?? (method.toUpperCase() !== "GET" && method.toUpperCase() !== "HEAD" ? await input.clone().text() : undefined));
    const response = await call("serverRequest", { path: url.pathname + url.search, method, body, contentType });
    if (!response.status) throw new TypeError("Sync server unreachable");
    const responseHeaders = response.contentType ? { "Content-Type": response.contentType } : {};
    return new Response(response.text || null, { status: response.status, headers: responseHeaders });
  }
  if (!isLocal(url)) return networkFetch(input, init);

  let method;
  let body;
  let contentType;
  let redirect;

  if (isUrlInput) {
    method = (init?.method || "GET").toUpperCase();
    redirect = init?.redirect || "follow";
    contentType = headerValue(init?.headers, "content-type");
    if (method !== "GET" && method !== "HEAD" && init?.body != null) {
      const raw = init.body;
      if (raw instanceof FormData) {
        body = encodeFormData(raw);
        contentType = "application/x-www-form-urlencoded";
      } else if (raw instanceof URLSearchParams) {
        body = raw.toString();
        contentType ||= "application/x-www-form-urlencoded";
      } else if (typeof raw === "string") {
        body = raw;
      } else {
        body = new Uint8Array(await new Response(raw).arrayBuffer());
      }
    }
  } else {
    const request = init ? new Request(input, init) : input;
    method = request.method.toUpperCase();
    redirect = request.redirect;
    contentType = request.headers.get("content-type") || undefined;
    if (method !== "GET" && method !== "HEAD") {
      if (contentType && contentType.startsWith("multipart/form-data")) {
        body = encodeFormData(await request.formData());
        contentType = "application/x-www-form-urlencoded";
      } else {
        body = new Uint8Array(await request.arrayBuffer());
      }
    }
  }
  const path = url.pathname + url.search;

  if (redirect === "manual") {
    // The demo's controllers post with redirect: "manual" and only need to know it went through.
    const result = await call("request", { method, path, body, contentType });
    const ok = result.status < 400;
    return new Response(null, { status: ok ? 200 : result.status });
  }
  const { result, redirected, finalPath } = await appRequest(method, path, body, contentType);
  const headers = result.headers.filter(([name]) => !/^(content-length|transfer-encoding)$/i.test(name));
  // The socket server adds this default when it writes a response; the reactor entry skips that
  // writer, and without it Turbo treats the page as a download and falls back to a full load.
  if (!headers.some(([name]) => name.toLowerCase() === "content-type")) headers.push(["Content-Type", "text/html; charset=utf-8"]);
  const response = new Response(result.body, { status: result.status, headers });
  if (typeof result.body === "string") {
    const bodyText = result.body;
    response.text = () => Promise.resolve(bodyText);
  }
  Object.defineProperty(response, "url", { value: new URL(finalPath, location.origin).href });
  Object.defineProperty(response, "redirected", { value: redirected });
  return response;
};

// The gem's service worker posts records_changed to its clients; the demo's layout turns that
// into this window event for pages that refresh in place, and reloads the rest.
// `changes` lists the records that changed as { type, id }, or is null when
// the sync pass could not list them: then anything may have changed.
function recordsChanged(changes) {
  if (document.querySelector("[data-instant-refresh]")) {
    window.dispatchEvent(new CustomEvent("instant-record:records-changed", { detail: { changes: changes || null } }));
  } else {
    window.location.reload(); // what the demo's layout does for pages without an in-place refresh
  }
}

// The shell began compiling the module before this script loaded; pass it on, and ask for the
// current page in the same message so boot and first render are one round trip.
// Who this browser is to the sync server, for models that declare sync_scope. Every tab of
// the browser shares it. Where storage is refused, the token lasts for this page.
function syncScope() {
  const key = "instant_record.sync_scope";
  try {
    const saved = localStorage.getItem(key);
    if (saved) return saved;
    const token = crypto.randomUUID();
    localStorage.setItem(key, token);
    return localStorage.getItem(key) || token;
  } catch {
    return crypto.randomUUID();
  }
}

const boot = await call("boot", { module: await window.__wasm, path: location.pathname + location.search, scope: syncScope() }).catch(error => {
  document.body.textContent = "The app could not open this release. Your saved database was kept. " + error.message;
  throw error;
});
marks.booted = performance.now();
marks.compileMs = window.__wasmMs ?? boot.compileMs;
const { result, finalPath } = boot.first;
marks.firstResponse = performance.now();
marks.firstRequestMs = result.ms;
if (finalPath !== location.pathname + location.search) history.replaceState(null, "", finalPath);
// Hand the document to the app's own page: its importmap, Turbo and Stimulus take over from here.
document.open();
document.write(result.status === 200 ? result.body : `<pre>${result.status}\n${(result.errors || []).join("\n")}</pre>`);
document.close();
document.addEventListener("turbo:before-visit", event => {
  if (mailboxScope(event.detail.url) !== initialScope) {
    event.preventDefault();
    location.assign(event.detail.url);
  }
});

marks.rendered = performance.now();


// Turbo and Stimulus handle their own forms first. An ordinary Rails form still
// submits locally in apps without either library.
async function submitLocalForm(event) {
  if (event.defaultPrevented || !(event.target instanceof HTMLFormElement)) return;
  const form = event.target;
  const button = event.submitter;
  const target = button?.getAttribute("formtarget") || form.target;
  const url = new URL(button?.getAttribute("formaction") || form.action, location.href);
  const method = (button?.getAttribute("formmethod") || form.method).toUpperCase();
  if (!isLocal(url) || method !== "POST" || (target && target !== "_self")) return;
  event.preventDefault();
  const fields = new FormData(form, button || undefined);
  const file = [...fields.values()].find(value => value instanceof File && value.name);
  if (file) {
    window.alert("This compiled runtime does not support file uploads.");
    return;
  }
  const response = await appRequest(method, url.pathname + url.search, encodeFormData(fields), "application/x-www-form-urlencoded");
  if (response.result.status >= 400) {
    document.open();
    document.write(response.result.body || "<p>Request failed</p>");
    document.close();
    window.addEventListener("submit", submitLocalForm);
    return;
  }
  if (response.redirected) location.assign(response.finalPath);
  else {
    document.open();
    document.write(response.result.body);
    document.close();
    window.addEventListener("submit", submitLocalForm);
  }
}
window.addEventListener("submit", submitLocalForm);
releaseRequired = watchRelease(networkFetch, import.meta.env.VITE_SOURCE_VERSION, () => waiting.size > 0);

// Resource Timing distinguishes a cached module from a network response and gives
// compressed and decoded byte counts without downloading the module a second time.
const resource = performance.getEntriesByName(new URL(import.meta.env.VITE_WASM_URL, location.origin).href).at(-1);
if (resource?.decodedBodySize) {
  const cached = resource.transferSize === 0;
  const compileEnd = window.__wasmStart + marks.compileMs;
  const ledger = { at: Date.now(), totalMs: marks.rendered - result.ms, entries: [
    { phase: "bundle", ms: resource.responseEnd - resource.startTime, bytes: resource.decodedBodySize,
      wireBytes: cached ? 0 : resource.encodedBodySize, cached },
    { phase: "compile", ms: Math.max(0, compileEnd - resource.responseEnd) },
    { phase: "sqlite", ms: boot.storageMs }, { phase: "vm", ms: boot.runtimeMs },
    { phase: "schema", ms: boot.bootstrapMs }, { phase: "render", ms: result.ms },
    ...(boot.shell ? [{ phase: "shell", ms: boot.shell.ms, bytes: boot.shell.bytes }] : []),
  ] };
  window.__spinel.ledger = ledger;
  try { localStorage.setItem("instant_record.compiled.boot." + (cached ? "cache" : "network"), JSON.stringify(ledger)); } catch {}
}
