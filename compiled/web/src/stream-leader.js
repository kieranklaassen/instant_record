// Leader-elected, visibility-aware SSE stream client for the compiled worker.
// One worker per (origin, scope) holds the streaming /events connection via
// navigator.locks and feeds complete SSE frames into the host; follower tabs
// receive persisted updates over BroadcastChannel and take over if the leader
// closes or enters simulated offline mode.

export const DEFAULTS = Object.freeze({
  hiddenGraceMs: 5000,
  peerTtlMs: 30000,
  peerPingWaitMs: 250,
  idleTimeoutMs: 60000,
  minStreamDurationMs: 2000,
  shortStreamDelayMs: 1000,
  shortStreamBusyDelayMs: 100,
  reconnectJitterMinMs: 50,
  reconnectJitterMaxMs: 150,
  backoffBaseMs: 1000,
  backoffCapMs: 30000,
  notReadyDelayMs: 250,
});

// Buffers incoming SSE text across arbitrary chunk boundaries (including CRLF
// split across chunks), emits complete \n\n-terminated frames that carry data,
// and drops comment-only heartbeat frames (": hb\n\n") without waking Wasm.
export class SseFrameBuffer {
  constructor() {
    this.pending = "";
    this.trailingCr = false;
  }

  feed(chunk) {
    if (!chunk) return { framesText: "", count: 0 };
    let text = this.trailingCr ? "\r" + chunk : chunk;
    this.trailingCr = false;
    if (text.endsWith("\r")) {
      this.trailingCr = true;
      text = text.slice(0, -1);
    }
    this.pending += text.replace(/\r\n?/g, "\n");

    const frames = [];
    let start = 0;
    let cut;
    while ((cut = this.pending.indexOf("\n\n", start)) !== -1) {
      const block = this.pending.slice(start, cut);
      start = cut + 2;
      if (/^data:/m.test(block)) frames.push(block + "\n\n");
    }
    if (start > 0) this.pending = this.pending.slice(start);
    return { framesText: frames.join(""), count: frames.length };
  }

  reset() {
    this.pending = "";
    this.trailingCr = false;
  }
}

export function streamScopeKey(mailboxScope = "", syncScope = "") {
  return `${mailboxScope || "default"}:${syncScope || "anon"}`;
}

export function eventsUrl(endpoint, { cursor = 0, identity = "", scope = "" } = {}) {
  const params = [`after=${encodeURIComponent(String(cursor ?? 0))}`];
  if (identity) params.push(`identity=${encodeURIComponent(identity)}`);
  if (scope) params.push(`scope=${encodeURIComponent(scope)}`);
  return `${endpoint}/events?${params.join("&")}`;
}

export function createStreamLeader(options) {
  const config = { ...DEFAULTS, ...options };
  const tabId = config.tabId || globalThis.crypto.randomUUID();
  const getEndpoint = typeof config.getEndpoint === "function" ? config.getEndpoint : () => config.endpoint;
  const getSyncScope = typeof config.getSyncScope === "function" ? config.getSyncScope : () => config.syncScope || "";
  const scopeKey = streamScopeKey(config.mailboxScope, getSyncScope());
  const lockName = `instant-record-stream/${scopeKey}`;
  const channelName = `instant-record-spinel-stream/${scopeKey}`;

  const locks = config.locks === undefined ? globalThis.navigator?.locks ?? null : config.locks;
  const createChannel = config.createChannel || (name => (typeof BroadcastChannel !== "undefined" ? new BroadcastChannel(name) : null));
  const fetchFn = config.fetch || ((...args) => globalThis.fetch(...args));
  const setTimer = config.setTimeout || ((fn, ms) => globalThis.setTimeout(fn, ms));
  const clearTimer = config.clearTimeout || (id => globalThis.clearTimeout(id));
  const now = config.now || (() => Date.now());
  const random = config.random || (() => Math.random());
  const isOnlineFn = config.isOnline || (() => (typeof navigator === "undefined" ? true : navigator.onLine !== false));
  const getLatencyMs = config.getLatencyMs || (() => 0);
  const onReport = config.onReport || (() => {});
  const onStreamStateChange = config.onStreamStateChange || (() => {});

  let channel = null;
  let started = false;
  let stopped = false;
  let suspended = false;
  let isLeader = false;
  let lockAbortController = null;
  let releaseLeadership = null;
  let activeLoop = null;

  let selfVisible = config.initialVisible !== false;
  let online = isOnlineFn();
  let offlineSimulated = !!(config.isOfflineSimulated && config.isOfflineSimulated());
  let pausedForHidden = false;
  let streamOpen = false;
  let backoffMs = config.backoffBaseMs;

  let fetchAbort = null;
  let abortReason = null;
  let hiddenGraceTimer = null;
  let wakeResolve = null;

  // peer tabId -> { visible: boolean, seenAt: number }
  const peers = new Map();

  const canElect = () => started && !stopped && !suspended && !offlineSimulated;
  const activeLeader = () => isLeader && !stopped && !suspended && !offlineSimulated;

  function eventsPathname() {
    try {
      const origin = globalThis.location?.origin || "http://localhost";
      return new URL(getEndpoint() + "/events", origin).pathname;
    } catch {
      return getEndpoint() + "/events";
    }
  }

  function reportStream(status, ms, open) {
    onReport({
      kind: "stream",
      method: "GET",
      path: eventsPathname(),
      status,
      ms,
      streamOpen: open,
    });
  }

  function postCoord(message) {
    if (!channel || stopped) return;
    try {
      channel.postMessage(message);
    } catch {
      // Channel closed during teardown.
    }
  }

  function updateStreamOpen(nextOpen, broadcast = false) {
    const normalized = !!nextOpen;
    if (streamOpen !== normalized) {
      streamOpen = normalized;
      onStreamStateChange(streamOpen);
    }
    if (broadcast && isLeader) {
      postCoord({ type: "stream_state", tabId, open: streamOpen });
    }
  }

  function anyVisible() {
    if (selfVisible) return true;
    for (const peer of peers.values()) {
      if (peer.visible) return true;
    }
    return false;
  }

  function hasStaleVisiblePeer() {
    const cutoff = now() - config.peerTtlMs;
    for (const peer of peers.values()) {
      if (peer.visible && peer.seenAt <= cutoff) return true;
    }
    return false;
  }

  function clearHiddenGrace() {
    if (hiddenGraceTimer !== null) {
      clearTimer(hiddenGraceTimer);
      hiddenGraceTimer = null;
    }
  }

  function wakeLoop() {
    const resolve = wakeResolve;
    wakeResolve = null;
    if (resolve) resolve();
  }

  function abortCurrentFetch(reason) {
    if (!fetchAbort) return;
    abortReason = reason;
    fetchAbort.abort();
  }

  function waitInterruptible(ms) {
    if (!activeLeader()) return Promise.resolve();
    return new Promise(resolve => {
      let timer = null;
      const done = () => {
        if (timer !== null) {
          clearTimer(timer);
          timer = null;
        }
        if (wakeResolve === done) wakeResolve = null;
        resolve();
      };
      wakeResolve = done;
      if (ms != null) timer = setTimer(done, Math.max(0, ms));
    });
  }

  function evaluateVisibility() {
    if (!activeLeader()) return;
    if (anyVisible()) {
      const wasHiddenOrGrace = pausedForHidden || hiddenGraceTimer !== null;
      clearHiddenGrace();
      if (pausedForHidden) {
        pausedForHidden = false;
        backoffMs = config.backoffBaseMs;
      }
      if (wasHiddenOrGrace) wakeLoop();
      return;
    }
    if (!pausedForHidden && hiddenGraceTimer === null) {
      hiddenGraceTimer = setTimer(() => {
        hiddenGraceTimer = null;
        if (!activeLeader() || anyVisible()) return;
        pausedForHidden = true;
        abortCurrentFetch("hidden");
      }, config.hiddenGraceMs);
    }
  }

  async function pruneStalePeers() {
    const pingStartedAt = now();
    postCoord({ type: "ping", tabId });
    await new Promise(resolve => setTimer(resolve, config.peerPingWaitMs));
    for (const [peerId, peer] of peers) {
      if (peer.visible && peer.seenAt < pingStartedAt) peers.delete(peerId);
    }
  }

  function jitteredDelay(baseMs) {
    return Math.round(baseMs * (0.8 + random() * 0.4));
  }

  function reconnectJitter() {
    const span = Math.max(0, config.reconnectJitterMaxMs - config.reconnectJitterMinMs);
    return Math.round(config.reconnectJitterMinMs + random() * span);
  }

  function handleCoordMessage(event) {
    const msg = event.data;
    if (!msg || typeof msg !== "object" || msg.tabId === tabId || stopped || suspended) return;

    if (msg.type === "hello" || msg.type === "visibility") {
      peers.set(msg.tabId, { visible: !!msg.visible, seenAt: now() });
      if (isLeader) {
        if (msg.type === "hello") postCoord({ type: "stream_state", tabId, open: streamOpen });
        evaluateVisibility();
      }
      return;
    }

    if (msg.type === "bye") {
      peers.delete(msg.tabId);
      if (isLeader) evaluateVisibility();
      return;
    }

    if (msg.type === "discover" || msg.type === "ping") {
      postCoord({ type: "visibility", tabId, visible: selfVisible });
      return;
    }

    if (msg.type === "stream_state") {
      if (!isLeader && !offlineSimulated) updateStreamOpen(!!msg.open, false);
      return;
    }

    if (msg.type === "wake") {
      if (isLeader) {
        backoffMs = config.backoffBaseMs;
        if (msg.visible) {
          peers.set(msg.tabId, { visible: true, seenAt: now() });
          clearHiddenGrace();
          pausedForHidden = false;
        }
        wakeLoop();
      }
      return;
    }

    if (msg.type === "reconnect") {
      if (isLeader) {
        backoffMs = config.backoffBaseMs;
        if (fetchAbort) abortCurrentFetch("reconnect");
        else wakeLoop();
      }
    }
  }

  async function openAndReadStream(params) {
    const latency = getLatencyMs();
    if (latency > 0) {
      await waitInterruptible(latency);
      if (!activeLeader() || !online || pausedForHidden) return;
    }

    const url = eventsUrl(getEndpoint(), {
      cursor: params.cursor,
      identity: params.identity,
      scope: getSyncScope(),
    });
    const controller = new AbortController();
    fetchAbort = controller;
    abortReason = null;

    let idleTimer = null;
    const armIdleWatchdog = () => {
      if (idleTimer !== null) clearTimer(idleTimer);
      if (config.idleTimeoutMs > 0) {
        idleTimer = setTimer(() => {
          abortReason = "idle";
          controller.abort();
        }, config.idleTimeoutMs);
      }
    };
    const clearIdleWatchdog = () => {
      if (idleTimer !== null) {
        clearTimer(idleTimer);
        idleTimer = null;
      }
    };

    const openedAt = now();
    let receivedEvents = 0;
    let wasReset = false;
    let failureStatus = null;
    let reader = null;

    try {
      armIdleWatchdog();
      const response = await fetchFn(url, {
        method: "GET",
        headers: { Accept: "text/event-stream" },
        signal: controller.signal,
      });

      if (!response || response.status !== 200) {
        failureStatus = response ? response.status : "failed";
      } else {
        backoffMs = config.backoffBaseMs;
        updateStreamOpen(true, true);

        const frameBuffer = new SseFrameBuffer();
        const consumeText = async text => {
          const { framesText, count } = frameBuffer.feed(text);
          if (count === 0) return false;
          receivedEvents += count;
          const applied = await config.applyFrames(framesText);
          if (activeLeader() && online && !pausedForHidden) {
            reportStream(200, Math.round(now() - openedAt), true);
          }
          if (applied?.reset) {
            wasReset = true;
            return true;
          }
          return false;
        };

        if (response.body && typeof response.body.getReader === "function") {
          reader = response.body.getReader();
          const decoder = new TextDecoder();
          while (true) {
            armIdleWatchdog();
            const { value, done } = await reader.read();
            if (done) {
              const tail = decoder.decode();
              if (tail) await consumeText(tail);
              break;
            }
            const chunk = typeof value === "string" ? value : decoder.decode(value, { stream: true });
            if (await consumeText(chunk)) {
              abortReason = "reset";
              controller.abort();
              break;
            }
          }
        } else {
          await consumeText(await response.text());
        }
      }
    } catch {
      failureStatus = "failed";
    } finally {
      clearIdleWatchdog();
      if (reader) {
        try { reader.cancel().catch(() => {}); } catch { /* ignore */ }
      }
      if (fetchAbort === controller) fetchAbort = null;
    }

    if (!activeLeader()) return;

    const reason = abortReason;
    abortReason = null;
    updateStreamOpen(false, true);

    if (wasReset || reason === "reconnect" || reason === "reset") return;
    if (reason === "hidden" || reason === "offline" || !online || pausedForHidden) return;

    if (failureStatus !== null) {
      reportStream(failureStatus, Math.round(now() - openedAt), false);
      const delay = jitteredDelay(backoffMs);
      backoffMs = Math.min(backoffMs * 2, config.backoffCapMs);
      await waitInterruptible(delay);
      return;
    }

    const elapsed = now() - openedAt;
    if (elapsed >= config.minStreamDurationMs) {
      await waitInterruptible(reconnectJitter());
    } else {
      await waitInterruptible(receivedEvents > 0 ? config.shortStreamBusyDelayMs : config.shortStreamDelayMs);
    }
  }

  async function runLeaderLoop() {
    while (activeLeader()) {
      if (!online) {
        updateStreamOpen(false, true);
        await waitInterruptible(null);
        continue;
      }

      if (!selfVisible && hasStaleVisiblePeer()) {
        await pruneStalePeers();
        if (!activeLeader()) break;
      }

      if (!anyVisible()) {
        if (!pausedForHidden) evaluateVisibility();
        else updateStreamOpen(false, true);
        await waitInterruptible(null);
        continue;
      }

      pausedForHidden = false;
      clearHiddenGrace();

      let params;
      try {
        params = await config.getStreamParams();
      } catch {
        params = null;
      }
      if (!activeLeader()) break;

      if (!params || !params.ready) {
        updateStreamOpen(false, true);
        await waitInterruptible(config.notReadyDelayMs);
        continue;
      }

      await openAndReadStream(params);
    }
  }

  async function assumeLeadership() {
    if (!canElect()) return;
    isLeader = true;
    peers.clear();
    pausedForHidden = !anyVisible();
    postCoord({ type: "discover", tabId });

    const released = new Promise(resolve => {
      releaseLeadership = resolve;
    });
    const loop = runLeaderLoop();
    activeLoop = loop;
    await released;

    isLeader = false;
    releaseLeadership = null;
    clearHiddenGrace();
    abortCurrentFetch(offlineSimulated ? "offline" : "release");
    wakeLoop();
    try {
      await loop;
    } finally {
      if (activeLoop === loop) activeLoop = null;
      if (canElect() && !isLeader && !lockAbortController) requestLeadership();
    }
  }

  function requestLeadership() {
    if (!canElect() || isLeader || lockAbortController || activeLoop) return;
    if (!locks) {
      assumeLeadership();
      return;
    }
    const abortController = new AbortController();
    lockAbortController = abortController;
    locks
      .request(lockName, { mode: "exclusive", signal: abortController.signal }, async () => {
        if (lockAbortController === abortController) lockAbortController = null;
        await assumeLeadership();
      })
      .catch(() => {
        if (lockAbortController === abortController) lockAbortController = null;
      })
      .finally(() => {
        if (canElect() && !isLeader && !lockAbortController && !activeLoop) {
          requestLeadership();
        }
      });
  }

  function releaseCurrentLeadership() {
    clearHiddenGrace();
    if (lockAbortController) {
      const pending = lockAbortController;
      lockAbortController = null;
      pending.abort();
    }
    if (isLeader) {
      abortCurrentFetch(offlineSimulated ? "offline" : "release");
      const release = releaseLeadership;
      releaseLeadership = null;
      wakeLoop();
      if (release) release();
    }
  }

  return {
    tabId,
    lockName,
    channelName,

    isLeader: () => isLeader,
    isStreamOpen: () => streamOpen,

    start() {
      if (started || stopped) return;
      started = true;
      channel = createChannel(channelName);
      if (channel) channel.onmessage = handleCoordMessage;
      postCoord({ type: "hello", tabId, visible: selfVisible });
      if (offlineSimulated) {
        reportStream("offline", 0, false);
        return;
      }
      requestLeadership();
    },

    setVisible(visible) {
      const next = !!visible;
      if (next === selfVisible) return;
      selfVisible = next;
      if (suspended || stopped) return;
      postCoord({ type: "visibility", tabId, visible: selfVisible });
      if (selfVisible) {
        clearHiddenGrace();
        if (isLeader) {
          pausedForHidden = false;
          backoffMs = config.backoffBaseMs;
          wakeLoop();
        } else {
          postCoord({ type: "wake", tabId, visible: true, reason: "visible" });
        }
      } else if (isLeader) {
        evaluateVisibility();
      }
    },

    setOnline(nextOnline) {
      const normalized = !!nextOnline;
      if (normalized === online) return;
      online = normalized;
      if (!online) {
        if (isLeader) {
          abortCurrentFetch("offline");
          updateStreamOpen(false, true);
        }
      } else {
        backoffMs = config.backoffBaseMs;
        if (isLeader) wakeLoop();
        else postCoord({ type: "wake", tabId, reason: "online" });
      }
    },

    setOfflineSimulated(nextOffline) {
      const normalized = !!nextOffline;
      if (normalized === offlineSimulated) return;
      offlineSimulated = normalized;
      if (offlineSimulated) {
        updateStreamOpen(false, false);
        reportStream("offline", 0, false);
        releaseCurrentLeadership();
      } else {
        backoffMs = config.backoffBaseMs;
        if (canElect()) {
          postCoord({ type: "hello", tabId, visible: selfVisible });
          postCoord({ type: "wake", tabId, visible: selfVisible, reason: "online" });
          requestLeadership();
        }
      }
    },

    wake() {
      if (!canElect()) return;
      backoffMs = config.backoffBaseMs;
      if (isLeader) wakeLoop();
      else postCoord({ type: "wake", tabId, visible: selfVisible, reason: "sync" });
    },

    reconnect() {
      if (!canElect()) return;
      backoffMs = config.backoffBaseMs;
      if (isLeader) {
        if (fetchAbort) abortCurrentFetch("reconnect");
        else wakeLoop();
      } else {
        postCoord({ type: "reconnect", tabId });
      }
    },

    // BFCache suspension: release the Web Lock and pause without permanently closing
    // the coordinator, so a subsequent pageshow (persisted) can resume cleanly.
    suspend() {
      if (stopped || suspended) return;
      suspended = true;
      selfVisible = false;
      postCoord({ type: "bye", tabId });
      updateStreamOpen(false, false);
      releaseCurrentLeadership();
    },

    resume(visible = true) {
      if (stopped || !suspended) return;
      suspended = false;
      selfVisible = !!visible;
      backoffMs = config.backoffBaseMs;
      if (started) {
        postCoord({ type: "hello", tabId, visible: selfVisible });
        if (!offlineSimulated) requestLeadership();
      }
    },

    stop() {
      if (stopped) return;
      stopped = true;
      suspended = false;
      postCoord({ type: "bye", tabId });
      updateStreamOpen(false, false);
      releaseCurrentLeadership();
      if (channel) {
        try { channel.close(); } catch { /* ignore */ }
        channel = null;
      }
    },
  };
}
