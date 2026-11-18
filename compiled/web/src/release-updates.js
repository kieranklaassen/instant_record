// Use the network fetch captured before the Rails request interceptor was installed.
export function watchRelease(fetchManifest, runningVersion, busy) {
  let checking = false;
  let pending = false;
  let edited = false;
  let notice;
  document.addEventListener("input", () => { edited = true; }, true);

  function activate() {
    if (!pending || document.hidden || !navigator.onLine || busy()) return;
    if (!edited && window.dispatchEvent(new Event("instant-record:before-update", { cancelable: true }))) {
      location.reload();
      return;
    }
    if (notice?.isConnected) return;
    notice = document.createElement("aside");
    notice.setAttribute("role", "status");
    notice.textContent = "An app update is ready. Finish your edits before reloading. ";
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = "Reload app";
    button.onclick = () => { if (!busy()) location.reload(); };
    notice.append(button);
    document.body.prepend(notice);
  }

  async function check() {
    if (checking || document.hidden) return;
    if (pending) return activate();
    checking = true;
    try {
      const response = await fetchManifest("/instant-record-release.json", { cache: "no-store" });
      if (!response.ok) return;
      const { version } = await response.json();
      pending = typeof version === "string" && /^[a-f0-9]{64}$/.test(version) && !version.startsWith(runningVersion);
      activate();
    } catch {
      // Offline clients keep running the installed release.
    } finally {
      checking = false;
    }
  }
  window.addEventListener("online", check);
  window.addEventListener("focus", check);
  document.addEventListener("visibilitychange", check);
  setInterval(check, 60000);
  return () => { pending = true; activate(); };
}
