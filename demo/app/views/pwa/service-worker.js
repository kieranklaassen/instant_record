// The service worker keeps the app shell. InstantRecord keeps the data.
//
// The shell is the page, its scripts, styles, fonts and the compiled module:
// what a browser needs before the app can start. With it cached, the app opens
// with no connection and InstantRecord serves the records from its local
// database.
//
// Everything else goes straight to the network, untouched. That is every
// request that is not a GET, InstantRecord's sync endpoints and its change
// stream. A worker that answered those would hand the sync loop old changes,
// or hold a stream open that it can never finish.
//
// There is no Background Sync here. The outbox is a table in the app's own
// database, and only the app can drain it. It drains when the app is open and
// the connection comes back.

const CACHE = "instant-record-shell-v1"
const SHELL = "/"
const FONT_HOSTS = ["fonts.googleapis.com", "fonts.gstatic.com"]
const SYNC_PATHS = [/(^|\/)instant_record(\/|$)/, /^\/email\/sync\//]
const ASSET_PATHS = [/^\/assets\//, /^\/harness\//, /\.wasm$/]
// Named after its content: by a digest in the name, or by the `?v=` the
// compiled build gives a script.
const IMMUTABLE_PATHS = [/^\/harness\//, /\.wasm$/, /-[0-9a-f]{8,}\.\w+$/]
const MODULES_KEPT = 2

self.addEventListener("install", (event) => {
  // A shell that cannot be fetched now is cached by the first page that loads.
  event.waitUntil(keep(SHELL).catch(() => {}).then(() => self.skipWaiting()))
})

self.addEventListener("activate", (event) => {
  event.waitUntil(dropOldCaches().then(() => self.clients.claim()))
})

self.addEventListener("fetch", (event) => {
  const { request } = event
  const kind = shellRequest(request)
  if (kind === "page") event.respondWith(page(request))
  if (kind === "asset") event.respondWith(asset(request))
})

// A page that loaded before this worker controlled it names what it loaded, so
// the first visit is enough to open offline.
self.addEventListener("message", (event) => {
  const { type, urls, page, shell } = event.data || {}
  if (type !== "instant_record.precache") return

  event.waitUntil(precache(Array.isArray(urls) ? urls : [], page, shell))
})

// "page", "asset", or nothing for a request this worker leaves alone.
function shellRequest(request) {
  if (request.method !== "GET") return
  if (request.headers.has("range")) return
  if ((request.headers.get("accept") || "").includes("text/event-stream")) return
  // The page asked for a fresh copy: a cold-boot measurement, a forced reload.
  if (request.cache === "reload" || request.cache === "no-store") return

  const kind = shellUrl(new URL(request.url))
  if (kind) return kind
  if (request.mode === "navigate" && sameOriginPage(new URL(request.url))) return "page"
}

function shellUrl(url) {
  if (FONT_HOSTS.includes(url.hostname)) return "asset"
  if (url.origin !== self.location.origin) return
  if (syncPath(url)) return
  if (ASSET_PATHS.some((path) => path.test(url.pathname))) return "asset"
}

function sameOriginPage(url) {
  return url.origin === self.location.origin && !syncPath(url)
}

function syncPath(url) {
  return SYNC_PATHS.some((path) => path.test(url.pathname))
}

// The network first, so a page is never older than the server's. With no
// network: this page as it was last seen, or else the shell.
async function page(request) {
  const cache = await caches.open(CACHE)
  try {
    const response = await fetch(request)
    if (response.ok && response.type === "basic") await cache.put(request.url, response.clone())
    return response
  } catch (error) {
    const kept = (await cache.match(request.url)) || (await cache.match(SHELL))
    if (kept) return kept
    throw error
  }
}

// The cache first. A file named after its content is never asked for again;
// any other is refreshed behind the answer. The refresh asks the server: the
// browser's own cache may hold the last release's copy for an hour yet, and
// kept from there the page of a new release would go on running an old script.
async function asset(request) {
  const cache = await caches.open(CACHE)
  const kept = await cache.match(request.url)
  const url = new URL(request.url)
  const immutable = url.searchParams.has("v") || IMMUTABLE_PATHS.some((path) => path.test(url.pathname))

  if (kept && immutable) return kept
  const fresh = keep(request.url, immutable ? {} : { cache: "no-cache" })
  if (!kept) return fresh

  fresh.catch(() => {})
  return kept
}

async function precache(urls, page, shell) {
  const cache = await caches.open(CACHE)
  const wanted = urls.map((url) => new URL(url, self.location.origin)).filter(shellUrl)

  await Promise.all(wanted.map(async (url) => {
    if (!(await cache.match(url.href))) await keep(url.href).catch(() => {})
  }))

  // The page itself, which loaded before this worker could keep it. In the
  // compiled app every path serves the same shell, so the newest one is also
  // kept for the paths this browser has not opened.
  if (typeof page !== "string") return
  const url = new URL(page, self.location.origin)
  if (!sameOriginPage(url)) return
  if (!shell && (await cache.match(url.href))) return

  const response = await fetch(url.href).catch(() => null)
  if (!response || !response.ok || response.type !== "basic") return
  if (shell) await cache.put(SHELL, response.clone())
  await cache.put(url.href, response)
}

// Fetches a URL and keeps the answer. Fonts are asked for with CORS, since a
// font is only usable from an answer the page is allowed to read.
async function keep(url, options = {}) {
  const sameOrigin = new URL(url, self.location.origin).origin === self.location.origin
  const response = await fetch(url, sameOrigin ? options : { ...options, mode: "cors", credentials: "omit" })

  if (response.ok) {
    const cache = await caches.open(CACHE)
    await cache.put(url, response.clone())
    if (/\.wasm$/.test(new URL(url, self.location.origin).pathname)) await dropOldModules(cache)
  }
  return response
}

// Each release has its own compiled module, and they are large. The newest
// ones stay, so a shell one release behind still starts.
async function dropOldModules(cache) {
  const modules = (await cache.keys()).filter((request) => /\.wasm$/.test(new URL(request.url).pathname))
  await Promise.all(modules.slice(0, -MODULES_KEPT).map((request) => cache.delete(request)))
}

async function dropOldCaches() {
  const names = await caches.keys()
  await Promise.all(names
    .filter((name) => name.startsWith("instant-record-shell-") && name !== CACHE)
    .map((name) => caches.delete(name)))
}
