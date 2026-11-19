// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "controllers"

// The service worker keeps the app shell; InstantRecord keeps the data
// (app/views/pwa/service-worker.js). This page loaded before the worker
// controlled it, so it names what it loaded: one visit is enough to open offline.
if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/service-worker.js")
    .then(() => navigator.serviceWorker.ready)
    .then((registration) => {
      registration.active.postMessage({
        type: "instant_record.precache",
        urls: performance.getEntriesByType("resource").map((entry) => entry.name),
        page: location.pathname + location.search,
        // The compiled app serves one shell on every path.
        shell: !!window.__spinel,
      })
    })
    .catch(() => {})
}
