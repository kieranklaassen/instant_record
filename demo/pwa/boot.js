async function registerServiceWorker() {
  const oldRegistrations = await navigator.serviceWorker.getRegistrations();
  for (const registration of oldRegistrations) {
    // An install already in flight: leave it alone. (Null for every worker that
    // is past install, which is every worker after a force reload — reading
    // .state here threw and left the launcher's buttons disabled forever.)
    if (registration.installing) {
      return;
    }
  }

  const workerUrl =
    import.meta.env.MODE === "production"
      ? "/rails.sw.js"
      : "/dev-sw.js?dev-sw";

  await navigator.serviceWorker.register(workerUrl, {
    scope: "/",
    type: "module",
  });
}

const fmtMs = (value) =>
  value >= 1000 ? `${(value / 1000).toFixed(1)}s` : `${Math.round(value)}ms`;

// One line per phase, as the worker measures it. Padded so the figures line up
// in a column — the numbers are the content here.
function ledgerLine(entry) {
  const cost = fmtMs(entry.ms).padStart(8);
  const bytes =
    entry.bytes === undefined
      ? ""
      : `  ${(entry.bytes / 1e6).toFixed(1)}MB${entry.cached === null ? "" : entry.cached ? " (cache)" : " (network)"}`;

  return `${entry.phase.padEnd(10)}${cost}${bytes}`;
}

async function boot({ bootMessage, bootProgress, bootConsoleOutput, bootLedger }) {
  if (!("serviceWorker" in navigator)) {
    console.error("Service Worker is not supported in this browser.");
    return;
  }

  if (!navigator.serviceWorker.controller) {
    await registerServiceWorker();

    bootMessage.textContent = "Waiting for Service Worker to activate...";
  } else {
    console.log("Service Worker already active.");
  }

  navigator.serviceWorker.addEventListener("message", function (event) {
    switch (event.data.type) {
      case "progress": {
        bootMessage.textContent = event.data.step;
        bootProgress.value = event.data.value;
        break;
      }
      case "console": {
        bootConsoleOutput.textContent += event.data.message + "\n";
        break;
      }
      case "instant_record.boot_phase": {
        if (bootLedger.dataset.started !== "true") {
          bootLedger.dataset.started = "true";
          bootLedger.textContent = "";
        }
        bootLedger.textContent += ledgerLine(event.data.entry) + "\n";
        break;
      }
      case "instant_record.boot_done": {
        const { build, ledger, totalMs, entries } = event.data.ledger;

        // A ledger that arrived without the phases (a page that asked a worker
        // which booted before it loaded) still prints them.
        if (bootLedger.dataset.started !== "true") {
          bootLedger.dataset.started = "true";
          bootLedger.textContent = entries.map(ledgerLine).join("\n") + "\n";
        }

        // Which worker is actually running. The dev worker's URL never changes,
        // so an edit can fail to reach the browser silently; this is the string
        // to check before trusting anything measured here.
        bootLedger.textContent +=
          `${"total".padEnd(10)}${fmtMs(totalMs ?? 0).padStart(8)}\n` +
          `\nworker build ${build} · ${ledger}\n`;
        break;
      }
      default: {
        console.log("Unknown message type:", event.data.type);
      }
    }
  });

  return await navigator.serviceWorker.ready;
}

// The DevTools "clear site data" ritual, as a button. Two steps: the worker lets
// go of the stream, the database, the caches and its registration, and then the
// splash deletes the database itself — which only a page no worker controls can
// do — and itemises the first-visit boot that follows.
async function wipeLocalData(registration) {
  const worker = registration.active;
  if (!worker) return registration.unregister();

  await new Promise((resolve) => {
    const channel = new MessageChannel();
    channel.port1.onmessage = resolve;
    worker.postMessage({ type: "instant_record.wipe_local_data" }, [channel.port2]);
  });
}

async function init() {
  const bootMessage = document.getElementById("boot-message");
  const bootProgress = document.getElementById("boot-progress");
  const bootConsoleOutput = document.getElementById("boot-console-output");
  const bootLedger = document.getElementById("boot-ledger");
  const registration = await boot({
    bootMessage,
    bootProgress,
    bootConsoleOutput,
    bootLedger,
  });
  if (!registration) {
    return;
  }
  bootMessage.textContent = "Service Worker Ready";
  bootProgress.value = 100;

  // A worker that booted before this page loaded still has its ledger.
  registration.active?.postMessage({ type: "instant_record.boot_ledger" });

  const launchButton = document.getElementById("launch-button");
  launchButton.disabled = false;
  launchButton.addEventListener("click", async function () {
    // Open in a new window
    window.open("/", "_blank");
  });

  const rebootButton = document.getElementById("reboot-button");
  rebootButton.disabled = false;
  rebootButton.addEventListener("click", async function () {
    if (!confirm("Delete the local database, caches and worker, then boot from scratch? Unsynced local writes are lost.")) {
      return;
    }

    rebootButton.disabled = true;
    bootMessage.textContent = "Closing the local database and unregistering the worker...";
    await wipeLocalData(registration);
    window.location.href = "/?instant_record_cold_boot=1";
  });

  const reloadButton = document.getElementById("reload-button");
  reloadButton.disabled = false;
  reloadButton.addEventListener("click", async function () {
    registration.active.postMessage({ type: "reload-rails" });
  });

  const reloadDebugButton = document.getElementById("reload-debug-button");
  reloadDebugButton.disabled = false;
  reloadDebugButton.addEventListener("click", async function () {
    registration.active.postMessage({ type: "reload-rails", debug: true });
  });
}

init();
