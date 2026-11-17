// Tab side (hand-written). Stands where the gem's service worker stands in the ruby.wasm build:
// every same-origin page request goes to the compiled app in the worker instead of the network,
// so the demo's own HTML, importmap, Turbo and Stimulus controllers run unchanged on top of it.
const worker = new Worker(new URL("./worker.js", import.meta.url), { type: "module" });
const waiting = new Map();
let nextId = 1;
worker.onmessage = (event) => {
  const { id, result, error, type } = event.data;
  if (type === "records_changed") return recordsChanged();
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

const marks = { start: performance.now() };
window.__spinel = { marks, call };

const isLocal = (url) => url.origin === location.origin &&
  !url.pathname.startsWith("/assets/") && !url.pathname.startsWith("/harness/") && !/^\/app[-.\w]*\.wasm$/.test(url.pathname);

// One page request; the worker follows the app's redirects and returns the final answer.
const appRequest = (method, path, body, contentType) => call("navigate", { method, path, body, contentType });

// The same seam a service worker's fetch handler is, from inside the page.
const networkFetch = window.fetch.bind(window);
window.fetch = async (input, init) => {
  const request = new Request(input, init);
  const url = new URL(request.url);
  if (!isLocal(url)) return networkFetch(input, init);

  const method = request.method.toUpperCase();
  let body;
  let contentType = request.headers.get("content-type") || undefined;
  if (method !== "GET" && method !== "HEAD") {
    if (contentType && contentType.startsWith("multipart/form-data")) {
      // The one-shot entry feeds the app's HTTP parser directly and skips the socket server's
      // multipart reader, so plain form fields travel urlencoded. File uploads are not carried.
      const form = await request.formData();
      const fields = new URLSearchParams();
      for (const [name, value] of form.entries()) if (typeof value === "string") fields.append(name, value);
      body = fields.toString();
      contentType = "application/x-www-form-urlencoded";
    } else {
      body = new Uint8Array(await request.arrayBuffer());
    }
  }
  const path = url.pathname + url.search;

  if (request.redirect === "manual") {
    // The demo's controllers post with redirect: "manual" and only need to know it went through.
    const result = await call("request", { method, path, body, contentType });
    const ok = result.status < 400;
    return new Response(null, { status: ok ? 200 : result.status });
  }
  const { result, redirected, finalPath } = await appRequest(method, path, body, contentType);
  const headers = result.headers.filter(([name]) => !/^(content-length|transfer-encoding)$/i.test(name));
  // The socket server adds this default when it writes a response; the one-shot entry skips that
  // writer, and without it Turbo treats the page as a download and falls back to a full load.
  if (!headers.some(([name]) => name.toLowerCase() === "content-type")) headers.push(["Content-Type", "text/html; charset=utf-8"]);
  const response = new Response(result.body, { status: result.status, headers });
  Object.defineProperty(response, "url", { value: new URL(finalPath, location.origin).href });
  Object.defineProperty(response, "redirected", { value: redirected });
  return response;
};

// The gem's service worker posts records_changed to its clients; the demo's layout turns that
// into this window event for pages that refresh in place, and reloads the rest.
function recordsChanged() {
  if (document.querySelector("[data-instant-refresh]")) {
    window.dispatchEvent(new CustomEvent("instant-record:records-changed"));
  } else {
    window.location.reload(); // what the demo's layout does for pages without an in-place refresh
  }
}

// The shell began compiling the module before this script loaded; pass it on, and ask for the
// current page in the same message so boot and first render are one round trip.
const boot = await call("boot", { module: await window.__wasm, path: location.pathname + location.search });
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
marks.rendered = performance.now();
