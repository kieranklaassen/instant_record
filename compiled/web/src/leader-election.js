// Single-leader election and peer RPC coordinator per (origin, scope).
//
// One dedicated worker per (origin, scope) acquires an exclusive Web Lock
// (`navigator.locks`) and owns the OPFS FileSystemSyncAccessHandle and hot AppHost.
// Peer tabs connect as followers over a lightweight control BroadcastChannel plus a
// dedicated per-follower RPC channel (compatible with MessageChannel ports), while
// queueing on the same Web Lock so browser-automatic lock release on leader close or
// crash promotes a surviving follower immediately.

export function leaderLockName(scope) {
  return "instant-record-leader" + (scope ? "/" + scope : "");
}

export function controlChannelName(scope) {
  return "instant-record-leader" + (scope ? "/" + scope : "");
}

export function peerChannelName(followerId) {
  return "instant-record-peer/" + followerId;
}

export function tabPresenceLockName(workerId) {
  return "instant-record-tab/" + workerId;
}

export function aggregateSimulations(leaderSim, peerSims) {
  const all = [leaderSim, ...peerSims].filter(Boolean);
  if (all.length === 0) return { offline: false, latencyMs: 0 };
  const offline = all.every(sim => !!sim.offline);
  let latencyMs = 0;
  for (const sim of all) {
    if (typeof sim.latencyMs === "number" && sim.latencyMs > latencyMs) latencyMs = sim.latencyMs;
  }
  return { offline, latencyMs };
}

function defaultCreateChannel(name) {
  if (typeof BroadcastChannel !== "function") return null;
  return new BroadcastChannel(name);
}

function makeId() {
  if (typeof globalThis.crypto?.randomUUID === "function") return globalThis.crypto.randomUUID();
  return "w-" + Math.random().toString(36).slice(2) + "-" + Date.now().toString(36);
}

export function createLeaderCoordinator({
  scope = "",
  sourceVersion = "",
  targetSchema = 0,
  workerId = makeId(),
  locks = globalThis.navigator?.locks,
  createChannel = defaultCreateChannel,
  onBecomeLeader,
  onRpc,
  onLeaderMessage,
  onLeaderSimulationChange,
  onFollowerPush,
  onRoleChange,
  discoveryRetryMs = 100,
  pruneIntervalMs = 2000,
  rpcLivenessMs = 1500,
} = {}) {
  const lockName = leaderLockName(scope);
  const controlName = controlChannelName(scope);

  let role = "idle"; // "idle" | "leader" | "follower" | "standalone"
  let closed = false;
  let epoch = 0;
  let storageMode = "indexeddb";

  // Leader state
  let releaseLeaderLock = null;
  let leaderBooting = false;
  let leaderReady = false;
  let lastBootResult = null;
  let leaderSim = { offline: false, latencyMs: 0, report: false };
  let lastEffectiveSim = { offline: false, latencyMs: 0 };
  const peers = new Map(); // followerId -> { port, simulation, alive }
  let pruneTimer = null;

  // Follower state
  let controlChannel = null;
  let peerChannel = null;
  let releaseTabLock = null;
  let activeLeaderId = null;
  let activeLeaderEpoch = 0;
  let attached = false;
  let discoveryTimer = null;
  let standbyActive = false;
  let localSim = { offline: false, latencyMs: 0, report: false };
  let nextRpcSeq = 1;
  const pendingRpcs = new Map(); // rpcId -> { method, payload, idempotent, acked, leaderId, resolve, reject, timer }
  const attachWaiters = [];

  function setRole(next) {
    if (role === next) return;
    role = next;
    onRoleChange?.(next);
  }

  function effectiveSimulation() {
    if (role === "standalone") return { offline: !!leaderSim.offline, latencyMs: Number(leaderSim.latencyMs) || 0 };
    const peerSims = [];
    for (const peer of peers.values()) peerSims.push(peer.simulation);
    return aggregateSimulations(leaderSim, peerSims);
  }

  function refreshEffectiveSimulation() {
    const next = effectiveSimulation();
    const prev = lastEffectiveSim;
    lastEffectiveSim = next;
    if (prev.offline !== next.offline || prev.latencyMs !== next.latencyMs) {
      onLeaderSimulationChange?.(next, prev);
    }
    return next;
  }

  function sendControl(msg) {
    try { controlChannel?.postMessage(msg); } catch {}
  }

  function broadcast(message, { excludeTabId = null } = {}) {
    if (role !== "leader") return;
    if (excludeTabId !== workerId) {
      onFollowerPush?.(message);
    }
    if (peers.size > 0) {
      sendControl({ type: "broadcast", leaderId: workerId, excludeTabId, message });
    }
  }

  function sendToPeer(followerId, message) {
    const peer = peers.get(followerId);
    if (!peer) return;
    try { peer.port.postMessage({ type: "push", leaderId: workerId, message }); } catch {}
  }

  function removePeer(followerId) {
    const peer = peers.get(followerId);
    if (!peer) return;
    peers.delete(followerId);
    try { peer.port.close(); } catch {}
    refreshEffectiveSimulation();
  }

  async function pruneDeadPeers() {
    if (role !== "leader" || peers.size === 0) return;
    if (typeof locks?.query !== "function") return;
    try {
      const state = await locks.query();
      const held = new Set((state?.held || []).map(entry => entry.name));
      for (const followerId of [...peers.keys()]) {
        if (!held.has(tabPresenceLockName(followerId))) {
          removePeer(followerId);
        }
      }
    } catch {
      // Ignore query failures in environments that restrict locks.query().
    }
  }

  function attachPeer(followerId, simulation, peerSourceVersion, peerTargetSchema) {
    if (role !== "leader") return;
    if (peerTargetSchema && targetSchema && peerTargetSchema < targetSchema) {
      sendControl({ type: "release_required", leaderId: workerId, targetId: followerId });
      return;
    }
    if (peerTargetSchema && targetSchema && peerTargetSchema > targetSchema) {
      onFollowerPush?.({ type: "release_required" });
    }
    let peer = peers.get(followerId);
    if (!peer) {
      const port = createChannel(peerChannelName(followerId));
      if (!port) return;
      peer = { port, simulation: simulation || { offline: false, latencyMs: 0, report: false } };
      port.onmessage = event => handleLeaderPeerMessage(followerId, event.data);
      peers.set(followerId, peer);
    } else if (simulation) {
      peer.simulation = simulation;
    }
    refreshEffectiveSimulation();
    try {
      peer.port.postMessage({
        type: "attached",
        leaderId: workerId,
        epoch,
        storageMode,
        sourceVersion,
        targetSchema,
      });
    } catch {}
  }

  async function handleLeaderPeerMessage(followerId, data) {
    if (!data || role !== "leader") return;
    if (data.leaderId && data.leaderId !== workerId) return;

    if (data.type === "ping") {
      const peer = peers.get(followerId);
      try { peer?.port.postMessage({ type: "pong", pingId: data.pingId, leaderId: workerId }); } catch {}
      return;
    }

    if (data.type === "simulate") {
      const peer = peers.get(followerId);
      if (peer) {
        peer.simulation = data.settings || { offline: false, latencyMs: 0, report: false };
        refreshEffectiveSimulation();
      }
      onLeaderMessage?.({ type: "simulate", settings: data.settings, backlog: !!data.backlog }, {
        tabId: followerId,
        reply: message => sendToPeer(followerId, message),
      });
      return;
    }

    if (data.type === "clear_log") {
      onLeaderMessage?.({ type: "clear_log" }, { tabId: followerId });
      return;
    }

    if (data.type === "rpc") {
      const peer = peers.get(followerId);
      if (!peer) return;
      try { peer.port.postMessage({ type: "rpc_ack", rpcId: data.rpcId, leaderId: workerId }); } catch {}
      try {
        const result = await onRpc(data.method, data.payload, { tabId: followerId });
        try { peer.port.postMessage({ type: "rpc_reply", rpcId: data.rpcId, leaderId: workerId, ok: true, result }); } catch {}
      } catch (error) {
        const message = String(error && error.message ? error.message : error);
        try { peer.port.postMessage({ type: "rpc_reply", rpcId: data.rpcId, leaderId: workerId, ok: false, error: message }); } catch {}
      }
    }
  }

  function handleControlMessage(event) {
    const data = event.data;
    if (!data || closed) return;

    if (role === "leader") {
      if (data.type === "who_is_leader") {
        if (data.targetSchema && targetSchema && data.targetSchema < targetSchema) {
          sendControl({ type: "release_required", leaderId: workerId, targetId: data.followerId });
          return;
        }
        if (data.targetSchema && targetSchema && data.targetSchema > targetSchema) {
          onFollowerPush?.({ type: "release_required" });
        }
        if (leaderReady) {
          sendControl({ type: "leader_ready", leaderId: workerId, epoch, storageMode, sourceVersion, targetSchema });
        } else if (leaderBooting) {
          sendControl({ type: "leader_booting", leaderId: workerId, epoch, sourceVersion, targetSchema });
        }
      } else if (data.type === "attach" && data.followerId && data.followerId !== workerId) {
        if (leaderReady) {
          attachPeer(data.followerId, data.simulation, data.sourceVersion, data.targetSchema);
        }
      } else if (data.type === "detach" && data.followerId) {
        removePeer(data.followerId);
      }
      return;
    }

    if (role === "follower") {
      if (data.type === "release_required" && (!data.targetId || data.targetId === workerId)) {
        onFollowerPush?.({ type: "release_required" });
        failAllPending("A newer Rails release migrated this database. Reload to continue.");
        return;
      }
      if (data.type === "leader_ready" && data.leaderId !== workerId) {
        if (data.targetSchema && targetSchema && data.targetSchema > targetSchema) {
          onFollowerPush?.({ type: "release_required" });
          failAllPending("A newer Rails release migrated this database. Reload to continue.");
          return;
        }
        const changed = activeLeaderId !== data.leaderId || activeLeaderEpoch !== data.epoch || !attached;
        activeLeaderId = data.leaderId;
        activeLeaderEpoch = data.epoch || 0;
        storageMode = data.storageMode || storageMode;
        if (changed) {
          attached = false;
          sendAttach();
        }
        return;
      }
      if (data.type === "leader_bye" && data.leaderId === activeLeaderId) {
        handleLeaderLost(data.leaderId);
        return;
      }
      if (data.type === "broadcast" && data.leaderId === activeLeaderId) {
        if (data.excludeTabId === workerId) return;
        const msg = data.message;
        if (msg?.type === "instant_record.debug" && !localSim.report) return;
        onFollowerPush?.(msg);
      }
    }
  }

  function handleFollowerPeerMessage(event) {
    const data = event.data;
    if (!data || role !== "follower" || closed) return;

    if (data.type === "attached" && data.leaderId) {
      activeLeaderId = data.leaderId;
      activeLeaderEpoch = data.epoch || 0;
      storageMode = data.storageMode || storageMode;
      attached = true;
      clearInterval(discoveryTimer);
      discoveryTimer = null;
      while (attachWaiters.length > 0) attachWaiters.shift().resolve();
      replayPendingRpcsToLeader();
      return;
    }

    if (data.type === "push" && data.leaderId === activeLeaderId) {
      onFollowerPush?.(data.message);
      return;
    }

    if (data.type === "rpc_ack" && data.leaderId === activeLeaderId) {
      const pending = pendingRpcs.get(data.rpcId);
      if (pending) {
        pending.acked = true;
        clearTimeout(pending.timer);
        pending.timer = null;
      }
      return;
    }

    if (data.type === "rpc_reply" && data.leaderId === activeLeaderId) {
      const pending = pendingRpcs.get(data.rpcId);
      if (!pending) return;
      clearTimeout(pending.timer);
      pendingRpcs.delete(data.rpcId);
      if (data.ok) pending.resolve(data.result);
      else pending.reject(new Error(data.error || "Leader RPC failed"));
      return;
    }
  }

  function sendAttach() {
    sendControl({
      type: "attach",
      followerId: workerId,
      simulation: localSim,
      sourceVersion,
      targetSchema,
    });
  }

  function sendRpcFrame(rpcId, pending) {
    pending.leaderId = activeLeaderId;
    pending.acked = false;
    clearTimeout(pending.timer);
    pending.timer = setTimeout(() => {
      if (role !== "follower" || !pendingRpcs.has(rpcId) || pending.acked) return;
      // Probe leader liveness if an RPC goes unacknowledged.
      sendControl({ type: "who_is_leader", followerId: workerId, sourceVersion, targetSchema });
    }, rpcLivenessMs);
    try {
      peerChannel?.postMessage({
        type: "rpc",
        rpcId,
        leaderId: activeLeaderId,
        followerId: workerId,
        method: pending.method,
        payload: pending.payload,
        idempotent: pending.idempotent,
      });
    } catch {}
  }

  function replayPendingRpcsToLeader() {
    for (const [rpcId, pending] of [...pendingRpcs.entries()]) {
      if (pending.leaderId === activeLeaderId) continue;
      if (pending.acked && !pending.idempotent) {
        clearTimeout(pending.timer);
        pendingRpcs.delete(rpcId);
        pending.reject(new Error("Leader closed while applying write; reload or retry."));
        continue;
      }
      sendRpcFrame(rpcId, pending);
    }
  }

  async function replayPendingRpcsLocally() {
    for (const [rpcId, pending] of [...pendingRpcs.entries()]) {
      clearTimeout(pending.timer);
      pendingRpcs.delete(rpcId);
      if (pending.acked && !pending.idempotent) {
        pending.reject(new Error("Leader closed while applying write; reload or retry."));
        continue;
      }
      try {
        const result = await onRpc(pending.method, pending.payload, { tabId: workerId });
        pending.resolve(result);
      } catch (error) {
        pending.reject(error);
      }
    }
  }

  function handleLeaderLost(deadLeaderId) {
    if (activeLeaderId !== deadLeaderId) return;
    activeLeaderId = null;
    attached = false;
    startDiscovery();
  }

  function failAllPending(message) {
    const error = new Error(message);
    for (const [rpcId, pending] of [...pendingRpcs.entries()]) {
      clearTimeout(pending.timer);
      pendingRpcs.delete(rpcId);
      pending.reject(error);
    }
    while (attachWaiters.length > 0) attachWaiters.shift().reject(error);
  }

  function startDiscovery() {
    if (discoveryTimer || role !== "follower" || closed) return;
    sendControl({ type: "who_is_leader", followerId: workerId, sourceVersion, targetSchema });
    discoveryTimer = setInterval(() => {
      if (role !== "follower" || attached || closed) {
        clearInterval(discoveryTimer);
        discoveryTimer = null;
        return;
      }
      sendControl({ type: "who_is_leader", followerId: workerId, sourceVersion, targetSchema });
    }, discoveryRetryMs);
  }

  function acquireTabPresenceLock() {
    if (typeof locks?.request !== "function") return Promise.resolve();
    return new Promise(resolveAcquired => {
      locks.request(tabPresenceLockName(workerId), () => {
        resolveAcquired();
        return new Promise(resolve => {
          releaseTabLock = resolve;
        });
      }).catch(() => resolveAcquired());
    });
  }

  async function enterLeaderRole({ promoted = false } = {}) {
    leaderBooting = true;
    leaderReady = false;
    epoch = Math.max(epoch + 1, activeLeaderEpoch + 1);
    setRole("leader");

    if (promoted) {
      clearInterval(discoveryTimer);
      discoveryTimer = null;
      if (peerChannel) {
        try { peerChannel.close(); } catch {}
        peerChannel = null;
      }
      leaderSim = { ...localSim };
      lastEffectiveSim = effectiveSimulation();
      activeLeaderId = null;
      attached = false;
    }

    const result = await onBecomeLeader({
      role: "leader",
      promoted,
      leaderId: workerId,
      epoch,
      broadcast,
      notifyOthers: (excludeTabId, message) => broadcast(message, { excludeTabId }),
      effectiveSimulation,
      pruneDeadPeers,
      connectedTabsCount: () => 1 + peers.size,
    });
    storageMode = result?.storageMode || storageMode;
    lastBootResult = result;
    leaderBooting = false;
    leaderReady = true;

    if (pruneIntervalMs > 0) {
      clearInterval(pruneTimer);
      pruneTimer = setInterval(pruneDeadPeers, pruneIntervalMs);
    }

    sendControl({ type: "leader_ready", leaderId: workerId, epoch, storageMode, sourceVersion, targetSchema });
    while (attachWaiters.length > 0) attachWaiters.shift().resolve();
    if (promoted && pendingRpcs.size > 0) {
      // Drain this tab's pending RPCs directly now that we own the reactor.
      replayPendingRpcsLocally();
    }
    return result;
  }

  function startStandbyLockWaiter() {
    if (standbyActive || closed) return;
    standbyActive = true;
    locks.request(lockName, async () => {
      standbyActive = false;
      if (closed) return;
      try {
        await enterLeaderRole({ promoted: true });
      } catch (error) {
        failAllPending(error?.message || String(error));
        return;
      }
      await new Promise(resolve => { releaseLeaderLock = resolve; });
    }).catch(() => {
      standbyActive = false;
    });
  }

  function waitForReady() {
    if ((role === "leader" && leaderReady) || role === "standalone" || attached) return Promise.resolve();
    return new Promise((resolve, reject) => {
      attachWaiters.push({ resolve, reject });
    });
  }

  async function start() {
    if (role !== "idle") return { role, storageMode };

    if (!locks || typeof locks.request !== "function" || typeof createChannel !== "function") {
      setRole("standalone");
      const result = await onBecomeLeader({
        role: "standalone",
        promoted: false,
        leaderId: workerId,
        epoch: 1,
        broadcast: message => onFollowerPush?.(message),
        notifyOthers: () => {},
        effectiveSimulation,
        pruneDeadPeers: async () => {},
        connectedTabsCount: () => 1,
      });
      storageMode = result?.storageMode || storageMode;
      return { role: "standalone", storageMode, bootResult: result };
    }

    controlChannel = createChannel(controlName);
    if (!controlChannel) {
      setRole("standalone");
      const result = await onBecomeLeader({
        role: "standalone",
        promoted: false,
        leaderId: workerId,
        epoch: 1,
        broadcast: message => onFollowerPush?.(message),
        notifyOthers: () => {},
        effectiveSimulation,
        pruneDeadPeers: async () => {},
        connectedTabsCount: () => 1,
      });
      storageMode = result?.storageMode || storageMode;
      return { role: "standalone", storageMode, bootResult: result };
    }

    controlChannel.onmessage = handleControlMessage;
    await acquireTabPresenceLock();

    let acquiredImmediate = false;
    let bootResult = null;
    await new Promise((resolveAttempt, rejectAttempt) => {
      locks.request(lockName, { ifAvailable: true }, async lock => {
        if (!lock) {
          resolveAttempt();
          return;
        }
        acquiredImmediate = true;
        try {
          bootResult = await enterLeaderRole({ promoted: false });
          resolveAttempt();
        } catch (error) {
          close({ announceBye: false });
          rejectAttempt(error);
          return;
        }
        await new Promise(resolve => { releaseLeaderLock = resolve; });
      }).catch(rejectAttempt);
    });

    if (acquiredImmediate) {
      return { role: "leader", storageMode, bootResult };
    }

    // Another worker holds the leader lock: attach as follower and queue for failover.
    setRole("follower");
    peerChannel = createChannel(peerChannelName(workerId));
    peerChannel.onmessage = handleFollowerPeerMessage;
    startStandbyLockWaiter();
    startDiscovery();
    await waitForReady();
    return { role, storageMode, bootResult: role === "leader" ? lastBootResult : null };
  }

  async function call(method, payload, { idempotent = true } = {}) {
    if (closed) throw new Error("Coordinator is closed");
    if ((role === "leader" && leaderReady) || role === "standalone") {
      return onRpc(method, payload, { tabId: workerId });
    }
    await waitForReady();
    if (role === "leader" || role === "standalone") {
      return onRpc(method, payload, { tabId: workerId });
    }
    const rpcId = workerId + ":" + (nextRpcSeq++);
    return new Promise((resolve, reject) => {
      const pending = { method, payload, idempotent, acked: false, leaderId: null, resolve, reject, timer: null };
      pendingRpcs.set(rpcId, pending);
      sendRpcFrame(rpcId, pending);
    });
  }

  function updateSimulation(settings, { backlog = false } = {}) {
    const normalized = {
      offline: !!settings?.offline,
      latencyMs: Number(settings?.latencyMs) || 0,
      report: !!settings?.report,
    };
    localSim = normalized;
    if (role === "leader" || role === "standalone") {
      leaderSim = normalized;
      refreshEffectiveSimulation();
      onLeaderMessage?.({ type: "simulate", settings: normalized, backlog }, {
        tabId: workerId,
        reply: message => onFollowerPush?.(message),
      });
      return;
    }
    if (role === "follower" && attached && activeLeaderId) {
      try {
        peerChannel?.postMessage({
          type: "simulate",
          leaderId: activeLeaderId,
          followerId: workerId,
          settings: normalized,
          backlog,
        });
      } catch {}
    }
  }

  function clearLog() {
    if (role === "leader" || role === "standalone") {
      onLeaderMessage?.({ type: "clear_log" }, { tabId: workerId });
      return;
    }
    if (role === "follower" && attached && activeLeaderId) {
      try {
        peerChannel?.postMessage({ type: "clear_log", leaderId: activeLeaderId, followerId: workerId });
      } catch {}
    }
  }

  function close({ announceBye = true } = {}) {
    if (closed) return;
    closed = true;
    clearInterval(discoveryTimer);
    clearInterval(pruneTimer);
    if (role === "leader") {
      if (announceBye) sendControl({ type: "leader_bye", leaderId: workerId });
      for (const peer of peers.values()) {
        try { peer.port.close(); } catch {}
      }
      peers.clear();
    } else if (role === "follower" && announceBye) {
      sendControl({ type: "detach", followerId: workerId });
    }
    if (peerChannel) {
      try { peerChannel.close(); } catch {}
      peerChannel = null;
    }
    if (controlChannel) {
      try { controlChannel.close(); } catch {}
      controlChannel = null;
    }
    if (releaseLeaderLock) {
      const release = releaseLeaderLock;
      releaseLeaderLock = null;
      release();
    }
    if (releaseTabLock) {
      const release = releaseTabLock;
      releaseTabLock = null;
      release();
    }
    failAllPending("Worker closed");
  }

  return {
    workerId,
    lockName,
    get role() { return role; },
    get storageMode() { return storageMode; },
    get activeLeaderId() { return activeLeaderId; },
    start,
    call,
    updateSimulation,
    clearLog,
    broadcast,
    notifyOthers: (excludeTabId, message) => broadcast(message, { excludeTabId }),
    effectiveSimulation,
    pruneDeadPeers,
    close,
  };
}
