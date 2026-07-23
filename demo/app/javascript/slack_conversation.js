// Conversation behavior for the Swiss Slack demo: infinite scroll-up through
// windowed history, in-place DOM morphing when synced records change (no
// full-page reloads), and a fetch-submitted composer. Vanilla JS on purpose —
// the demo's point is plain Rails running in the browser; this module is
// presentation glue over the fragment contract in
// app/views/slack/channels/_messages.html.erb.

const PAGE_SIZE = 50;
const BOTTOM_SLACK_PX = 60;

let bound = false;

const root = () => document.querySelector("[data-instant-refresh]");
const scroller = () => root()?.querySelector(".message-scroll");
const list = () => root()?.querySelector("ol.messages");
const swControlled = () =>
  "serviceWorker" in navigator && !!navigator.serviceWorker.controller;

// Per-page-load conversation state. Cursor data lives on the <ol> dataset
// (the fragment re-renders it); this only tracks what the DOM cannot say.
const state = {
  fetchingHistory: false,
  refreshQueued: false,
  refreshing: false,
  exhausted: false,
  observer: null,
  sentinel: null,
};

const init = () => {
  const container = scroller();
  if (!container || container.dataset.conversationReady) return;
  container.dataset.conversationReady = "true";

  state.observer?.disconnect();
  state.fetchingHistory = false;
  state.refreshing = false;
  state.refreshQueued = false;
  state.exhausted = list()?.dataset.hasMore !== "true";
  scrollToBottom();
  mountSentinel();
  bindOnce();
};

const bindOnce = () => {
  if (bound) return;
  bound = true;

  // The layout's reload listener defers to us on pages with an
  // instant-refresh root (see layouts/application.html.erb). A completed sync
  // pass also proves the VM is responsive, so re-arm a sentinel that a
  // transient busy/timeout had parked.
  window.addEventListener("instant-record:records-changed", () => {
    refreshLive();
    rearmSentinel();
  });
  window.addEventListener("online", rearmSentinel);
  document.addEventListener("submit", onSubmit);
};

// Turbo Drive is active demo-wide; a visit into the conversation page swaps
// the body without re-running module top-level code, so re-init on every
// Turbo load (handlers above are delegated and query the DOM at event time).
document.addEventListener("turbo:load", init);

// --- Infinite scroll -------------------------------------------------------

const mountSentinel = () => {
  if (state.exhausted) return markBeginning();

  const sentinel = document.createElement("div");
  sentinel.className = "history-sentinel";
  sentinel.dataset.state = "idle";
  scroller().prepend(sentinel);
  state.sentinel = sentinel;

  state.observer = new IntersectionObserver(
    (entries) => entries.some((entry) => entry.isIntersecting) && loadOlder(),
    { root: scroller() },
  );
  state.observer.observe(sentinel);
};

const loadOlder = async () => {
  if (state.fetchingHistory || state.exhausted) return;

  const messages = list();
  const before = {
    created_at: messages.dataset.oldestCreatedAt,
    id: messages.dataset.oldestId,
  };
  // A fresh client can render before bootstrap fills the cursor attributes;
  // firing with blank cursors would 500 the fetch. Wait for the next
  // records_changed, which re-arms the sentinel.
  if (!before.created_at || !before.id) return;

  state.fetchingHistory = true;
  setSentinel("loading", "Loading history…");

  try {
    let hasMore = null;
    if (swControlled()) {
      // Pull the older page into the local database first; the VM fetches
      // from the real server only when the page isn't already local.
      const reply = await fetchHistoryViaWorker({
        type: "Message",
        partition: messages.dataset.channelId,
        before,
        limit: PAGE_SIZE,
      });
      // busy/timeout are transient (the VM was mid-sync), not offline: leave
      // the observer armed so the next scroll or sync retries. Only a genuine
      // fetch failure disarms and waits for reconnect.
      if (reply.busy) return setSentinel("idle", "");
      if (!reply.ok) return offline(reply.error);
      hasMore = reply.has_more;
    }

    const fragment = await fetchFragment(before);
    if (!fragment) return offline("fragment fetch failed");

    prependHistory(fragment);
    if (hasMore === null) hasMore = fragment.dataset.hasMore === "true";
    if (!hasMore) exhaust();
    else setSentinel("idle", "");
  } finally {
    state.fetchingHistory = false;
    // A records_changed that arrived mid-prepend was deferred; run it now.
    if (state.refreshQueued) {
      state.refreshQueued = false;
      const queuedForceBottom = state.queuedForceBottom || false;
      state.queuedForceBottom = false;
      refreshLive({ forceBottom: queuedForceBottom });
    }
  }
};

const fetchHistoryViaWorker = (request) =>
  new Promise((resolve) => {
    const channel = new MessageChannel();
    // Transient: an unresponsive worker recovers on the next records_changed;
    // busy keeps the sentinel armed instead of latching the offline notice.
    const timer = setTimeout(
      () => resolve({ ok: false, busy: true, error: "history request timed out" }),
      15000,
    );
    channel.port1.onmessage = (event) => {
      clearTimeout(timer);
      resolve(event.data || { ok: false, error: "empty reply" });
    };
    navigator.serviceWorker.controller.postMessage(
      { type: "instant_record.fetch_history", request },
      [channel.port2],
    );
  });

const fetchFragment = async (before) => {
  const url = new URL(list().dataset.fragmentUrl, window.location.origin);
  url.searchParams.set("floor_created_at", before.created_at);
  url.searchParams.set("floor_id", before.id);
  url.searchParams.set("deepen", "1");

  try {
    const response = await fetch(url);
    if (!response.ok) return null;
    const doc = new DOMParser().parseFromString(await response.text(), "text/html");
    return doc.querySelector("ol.messages");
  } catch {
    return null;
  }
};

// Prepend rows the current list doesn't have, keeping the viewport anchored
// on the first previously-visible message.
const prependHistory = (fragment) => {
  const container = scroller();
  const messages = list();
  const known = new Set(
    [...messages.children].map((li) => li.dataset.id).filter(Boolean),
  );

  const fresh = [...fragment.children].filter(
    (li) => li.dataset.id && !known.has(li.dataset.id),
  );
  const heightBefore = container.scrollHeight;
  messages.prepend(...fresh.map((li) => li.cloneNode(true)));
  container.scrollTop += container.scrollHeight - heightBefore;

  messages.dataset.oldestCreatedAt = fragment.dataset.oldestCreatedAt;
  messages.dataset.oldestId = fragment.dataset.oldestId;
};

const exhaust = () => {
  state.exhausted = true;
  state.observer?.disconnect();
  state.sentinel?.remove();
  state.sentinel = null;
  markBeginning();
};

const markBeginning = () => {
  if (scroller().querySelector(".beginning-marker")) return;
  const marker = document.createElement("div");
  marker.className = "beginning-marker";
  marker.innerHTML = `<span class="micro-label">Beginning of history</span>`;
  scroller().prepend(marker);
};

const offline = (reason) => {
  console.warn("[slack] history unavailable:", reason);
  setSentinel("offline", "History is unavailable offline — reconnect to load more.");
  state.observer?.disconnect();
};

const rearmSentinel = () => {
  if (state.exhausted || !state.sentinel) return;
  setSentinel("idle", "");
  state.observer?.observe(state.sentinel);
};

const setSentinel = (mode, text) => {
  if (!state.sentinel) return;
  state.sentinel.dataset.state = mode;
  state.sentinel.textContent = text;
};

// --- Live updates ----------------------------------------------------------

// Re-fetch the page (floor preserved, so loaded scrollback survives) and
// reconcile in place: new messages appear, destroyed ones drop out, badges
// flip — without touching scroll position unless the reader was at bottom.
const refreshLive = async ({ forceBottom = false } = {}) => {
  // Never morph while a history page is being prepended: the two writers
  // share the message list and the floor cursor, and a mid-flight morph would
  // fight the prepend. Queue and let loadOlder's completion trigger the next
  // records_changed, or run once it clears.
  if (state.refreshing || state.fetchingHistory) {
    state.refreshQueued = true;
    state.queuedForceBottom = state.queuedForceBottom || forceBottom;
    return;
  }
  state.refreshing = true;

  try {
    const container = scroller();
    const messages = list();
    const stick = forceBottom || nearBottom(container);

    const url = new URL(window.location.href);
    if (messages.dataset.oldestId) {
      url.searchParams.set("floor_created_at", messages.dataset.oldestCreatedAt);
      url.searchParams.set("floor_id", messages.dataset.oldestId);
    }

    let doc;
    try {
      const response = await fetch(url);
      // The channel may have been destroyed (e.g. reset) — fall back to
      // navigation rather than morphing against an error page.
      if (!response.ok) return void (window.location.href = "/slack");
      doc = new DOMParser().parseFromString(await response.text(), "text/html");
    } catch {
      return; // offline: keep the current DOM, the next sync retries
    }

    const freshList = doc.querySelector("ol.messages");
    if (!freshList) return void (window.location.href = "/slack");

    // The floor we *requested* bounds the fetched range [floor, newest]; any
    // DOM row at or above it that the fresh list dropped is a real deletion.
    // (Using the fresh list's own oldest instead would keep a just-deleted
    // floor row as a ghost, since the survivors start one row newer.)
    const requestedFloor = messages.dataset.oldestId
      ? { at: messages.dataset.oldestCreatedAt, id: messages.dataset.oldestId }
      : null;
    morphMessages(messages, freshList, requestedFloor);
    replaceRegion(".sidebar", doc);
    replaceRegion(".conversation-header", doc);
    if (stick) scrollToBottom();
  } finally {
    state.refreshing = false;
    if (state.refreshQueued) {
      state.refreshQueued = false;
      const queuedForceBottom = state.queuedForceBottom || false;
      state.queuedForceBottom = false;
      refreshLive({ forceBottom: queuedForceBottom });
    }
  }
};

// Merge by data-id: both lists are ascending (created_at, id), so one pass
// inserts new rows in order, updates changed ones, and removes the missing.
// Rows without data-id (markers) are JS- or server-owned and left alone.
// `requestedFloor` is the keyset the fetch asked for — its lower bound, so
// only rows at or above it are in scope for removal.
const morphMessages = (current, fresh, requestedFloor) => {
  const existing = new Map(
    [...current.children].map((li) => [li.dataset.id, li]),
  );
  existing.delete(undefined);

  const freshIds = new Set(
    [...fresh.children].map((li) => li.dataset.id).filter(Boolean),
  );

  let anchor = null;
  for (const freshLi of [...fresh.children]) {
    const id = freshLi.dataset.id;
    if (!id) continue;

    let node = existing.get(id);
    if (node) {
      existing.delete(id);
      if (node.outerHTML !== freshLi.outerHTML) {
        const updated = freshLi.cloneNode(true);
        node.replaceWith(updated);
        node = updated;
      }
    } else {
      node = freshLi.cloneNode(true);
      anchor ? anchor.after(node) : current.prepend(node);
    }
    anchor = node;
  }

  // A DOM row the fresh list dropped is a genuine deletion only when it lies
  // within the range the fetch actually covered: at or above the REQUESTED
  // floor. Rows below that floor (e.g. a back-skewed-clock send) were never
  // in scope and stay. Using the requested floor — not the fresh list's own
  // oldest — is what lets a just-deleted floor row be removed instead of
  // lingering as a ghost after a reset.
  for (const leftover of existing.values()) {
    if (freshIds.has(leftover.dataset.id)) continue;
    if (requestedFloor && belowFloor(leftover, requestedFloor.at, requestedFloor.id)) continue;
    leftover.remove();
  }
};

// A DOM row's timestamp is display-only (%H:%M), so membership below the
// floor is judged by id/attribute presence, not a parsed clock: rows are
// only removable when they sit within the fetched keyset range. We keep any
// row the fresh fetch did not cover below its oldest cursor.
const belowFloor = (li, floorAt, floorId) => {
  const at = li.dataset.createdAt;
  if (!at) return false;
  if (at < floorAt) return true;
  return at === floorAt && li.dataset.id < floorId;
};

const replaceRegion = (selector, doc) => {
  const current = root().querySelector(selector);
  const fresh = doc.querySelector(selector);
  if (!current || !fresh) return;
  // Skip identical regions: no DOM churn, no lost hover/focus states.
  if (current.outerHTML === fresh.outerHTML) return;
  current.replaceWith(fresh.cloneNode(true));
};

// --- Composer and reset (delegated: both survive sidebar/header morphs) ----

const onSubmit = (event) => {
  const form = event.target;
  if (form.matches(".composer")) return sendMessage(event, form);
  if (form.matches(".reset-form")) return resetDemo(event, form);
};

const sendMessage = async (event, form) => {
  if (!root()) return; // plain form fallback off this page
  event.preventDefault();

  const input = form.querySelector("input[type='text']");
  const typed = input.value;
  const body = new FormData(form);
  input.value = "";
  input.focus();

  try {
    const response = await fetch(form.action, { method: "POST", body });
    if (!response.ok) throw new Error(`send failed: ${response.status}`);
    // The local write is already committed; render it now rather than
    // waiting for the next sync tick's records_changed.
    refreshLive({ forceBottom: true });
  } catch {
    input.value = typed;
    form.submit(); // plain navigation fallback
  }
};

const resetDemo = (event, form) => {
  event.preventDefault();
  fetch(form.action, { method: "POST" })
    .then((response) => {
      if (!response.ok) throw new Error(`reset failed: ${response.status}`);
      // Server-rendered pages have no service worker to push the change;
      // reload directly so the reset is visible immediately.
      if (!swControlled()) window.location.reload();
    })
    .catch(() => {
      alert(
        "Reset needs the sync server — you appear to be offline. Try again once you're connected.",
      );
    });
};

// --- Helpers ---------------------------------------------------------------

const nearBottom = (container) =>
  container.scrollHeight - container.scrollTop - container.clientHeight <
  BOTTOM_SLACK_PX;

const scrollToBottom = () => {
  const container = scroller();
  if (container) container.scrollTop = container.scrollHeight;
};

document.readyState === "loading"
  ? document.addEventListener("DOMContentLoaded", init)
  : init();
