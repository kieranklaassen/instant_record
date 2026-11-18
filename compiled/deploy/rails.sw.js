// Retires the service worker that the ruby.wasm build registered at this path.
//
// A browser that still has that worker asks for this file on its next visit,
// finds different bytes and installs this one in its place. This one removes
// its own registration and reloads the open
// tabs, which then load from the network like any first visit.
//
// Only needed on a host that used to serve the ruby.wasm build.

self.addEventListener("install", () => self.skipWaiting());

self.addEventListener("activate", (event) => {
  event.waitUntil(retire());
});

async function retire() {
  await self.registration.unregister();

  const tabs = await self.clients.matchAll({ type: "window" });
  await Promise.all(tabs.map((tab) => tab.navigate(tab.url).catch(() => {})));
}
