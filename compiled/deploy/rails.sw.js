// Retires the service worker that the ruby.wasm build registered at this path.
//
// A browser that still has that worker asks for this file on its next visit,
// finds different bytes and installs this one in its place. This one removes
// its own registration, clears what the old worker stored, and reloads the open
// tabs, which then load from the network like any first visit.
//
// Only needed on a host that used to serve the ruby.wasm build.

const OLD_DATABASE = "/pglite/instant_record_demo";

self.addEventListener("install", () => self.skipWaiting());

self.addEventListener("activate", (event) => {
  event.waitUntil(retire());
});

async function retire() {
  await self.registration.unregister();
  await Promise.all((await caches.keys()).map((key) => caches.delete(key)));

  const tabs = await self.clients.matchAll({ type: "window" });
  await Promise.all(tabs.map((tab) => tab.navigate(tab.url).catch(() => {})));

  await dropOldDatabase();
}

// The old worker keeps its database open until the browser stops it, so the
// delete can wait a while. Give up after ten seconds: the data is only unused.
function dropOldDatabase() {
  return new Promise((resolve) => {
    setTimeout(resolve, 10000);
    try {
      const request = indexedDB.deleteDatabase(OLD_DATABASE);
      request.onsuccess = resolve;
      request.onerror = resolve;
    } catch {
      resolve();
    }
  });
}
