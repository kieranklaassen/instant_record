// Visual staging-branch preview overlay for compiled InstantRecord apps.
//
// Mounted in a Shadow DOM host by `main.js` so every compiled Rails app gets a
// consistent, style-isolated staging preview bar, expandable OutboxMutation diff
// inspector, and Approve & Sync / Discard controls without editing host views.

export function formatBreakdown(byOperation = {}) {
  const parts = [];
  if (byOperation.create) parts.push(`${byOperation.create} created`);
  if (byOperation.update) parts.push(`${byOperation.update} updated`);
  if (byOperation.destroy) parts.push(`${byOperation.destroy} deleted`);
  return parts.join(" · ");
}

export function formatMutationSummary(mutation) {
  const op = String(mutation.operation || "change").toUpperCase();
  const type = String(mutation.record_type || "Record");
  const id = String(mutation.record_id || "").slice(0, 8);
  const changes = mutation.changes && typeof mutation.changes === "object"
    ? Object.keys(mutation.changes).filter((key) => !["id", "created_at", "updated_at", "server_version", "sync_state"].includes(key))
    : [];
  const fields = changes.length ? ` (${changes.join(", ")})` : "";
  return `${op} ${type}#${id}${fields}`;
}

export function formatOutcomeNotice(action) {
  if (!action) return "";
  if (action.approved) {
    const conflictNote = action.skipped > 0
      ? ` · ${action.skipped} skipped (LWW conflict)`
      : "";
    const rebaseNote = action.mainDeltasDuringReview > 0
      ? ` · preserved ${action.mainDeltasDuringReview} main ${action.mainDeltasDuringReview === 1 ? "update" : "updates"}`
      : "";
    return `Approved '${action.name}': ${action.applied} ${action.applied === 1 ? "mutation" : "mutations"} replayed onto main${conflictNote}${rebaseNote}`;
  }
  if (action.discarded) {
    return `Discarded '${action.name}': ${action.dropped} staged ${action.dropped === 1 ? "change" : "changes"} dropped · 0 server impact`;
  }
  return "";
}

const STYLES = `
  :host {
    all: initial;
    font-family: Figtree, ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
    color: #302B26;
  }
  .launcher {
    position: fixed;
    right: 16px;
    bottom: 16px;
    z-index: 9000;
    display: inline-flex;
    align-items: center;
    gap: 8px;
    height: 36px;
    padding: 0 14px;
    border: 1px solid #E2D9CC;
    border-radius: 9999px;
    background: #FFFFFF;
    color: #302B26;
    font: 600 13px/1 inherit;
    box-shadow: 0 10px 24px -14px rgba(48, 43, 38, 0.35), 0 0 0 1px rgba(10, 10, 10, 0.04);
    cursor: pointer;
  }
  .launcher:hover { background: #FBF8F2; }
  .launcher:disabled { opacity: 0.6; cursor: default; }
  .dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: #B07A2A;
    flex: none;
  }
  .banner {
    position: fixed;
    left: 50%;
    bottom: 16px;
    transform: translateX(-50%);
    z-index: 9100;
    width: min(760px, calc(100vw - 24px));
    border-radius: 16px;
    background: #302B26;
    color: #FBF8F2;
    box-shadow: 0 20px 44px -18px rgba(48, 43, 38, 0.65), 0 0 0 1px rgba(251, 248, 242, 0.14);
    overflow: hidden;
  }
  .bar {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: 10px 14px;
    padding: 10px 14px;
  }
  .meta {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 8px;
    min-width: 0;
  }
  .pill {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    height: 24px;
    padding: 0 10px;
    border-radius: 9999px;
    background: rgba(251, 239, 216, 0.16);
    color: #FBEFD8;
    font-size: 12px;
    font-weight: 600;
    white-space: nowrap;
  }
  .pill-rebase {
    background: rgba(62, 138, 91, 0.28);
    color: #D7F5E3;
  }
  .summary {
    font-size: 13px;
    color: rgba(251, 248, 242, 0.88);
  }
  .actions {
    display: flex;
    align-items: center;
    gap: 8px;
  }
  button.btn {
    height: 30px;
    padding: 0 12px;
    border: 0;
    border-radius: 9999px;
    font: 600 12px/1 inherit;
    cursor: pointer;
    white-space: nowrap;
  }
  button.btn:disabled { opacity: 0.55; cursor: default; }
  button.btn-diff {
    background: rgba(255, 255, 255, 0.12);
    color: #FBF8F2;
  }
  button.btn-diff:hover { background: rgba(255, 255, 255, 0.2); }
  button.btn-discard {
    background: rgba(255, 233, 228, 0.16);
    color: #FFD6CE;
  }
  button.btn-discard:hover { background: rgba(255, 233, 228, 0.26); }
  button.btn-approve {
    background: #3E8A5B;
    color: #FFFFFF;
  }
  button.btn-approve:hover { filter: brightness(1.08); }
  .diff {
    max-height: 220px;
    overflow-y: auto;
    border-top: 1px solid rgba(251, 248, 242, 0.12);
    padding: 8px 14px 10px;
    background: rgba(0, 0, 0, 0.18);
    font-family: "JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, monospace;
    font-size: 11px;
  }
  .diff ul {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }
  .diff li {
    color: rgba(251, 248, 242, 0.88);
    word-break: break-word;
  }
  .notice {
    position: fixed;
    left: 50%;
    bottom: 62px;
    transform: translateX(-50%);
    z-index: 9050;
    max-width: min(680px, calc(100vw - 24px));
    padding: 8px 14px;
    border-radius: 9999px;
    background: #302B26;
    color: #FBF8F2;
    font-size: 12px;
    font-weight: 500;
    box-shadow: 0 12px 26px -14px rgba(48, 43, 38, 0.5);
  }
  .edge {
    position: fixed;
    inset: 0;
    z-index: 8999;
    pointer-events: none;
    box-shadow: inset 0 0 0 3px rgba(176, 122, 42, 0.55);
  }
`;

export function mountBranchPreview(api) {
  if (typeof document === "undefined") return () => {};

  let state = { active: false };
  let diffOpen = false;
  let busy = false;
  let noticeText = "";
  let noticeTimer = null;
  let hostEl = null;
  let shadow = null;

  function ensureMounted() {
    if (!document.body) return false;
    if (hostEl && hostEl.isConnected) return true;
    hostEl = document.createElement("div");
    hostEl.id = "instant-record-branch-preview";
    hostEl.setAttribute("data-turbo-permanent", "");
    shadow = hostEl.attachShadow({ mode: "open" });
    document.body.appendChild(hostEl);
    return true;
  }

  function showNotice(text) {
    clearTimeout(noticeTimer);
    noticeText = text;
    render();
    if (text) {
      noticeTimer = setTimeout(() => {
        noticeText = "";
        render();
      }, 5000);
    }
  }

  async function runAction(fn) {
    if (busy) return;
    busy = true;
    render();
    try {
      const result = await fn();
      const text = formatOutcomeNotice(result);
      if (text) showNotice(text);
    } catch (error) {
      showNotice(error?.message || String(error));
    } finally {
      busy = false;
      render();
    }
  }

  function render() {
    if (!ensureMounted()) return;
    shadow.replaceChildren();

    const style = document.createElement("style");
    style.textContent = STYLES;
    shadow.appendChild(style);

    if (noticeText) {
      const toast = document.createElement("div");
      toast.className = "notice";
      toast.setAttribute("role", "status");
      toast.textContent = noticeText;
      shadow.appendChild(toast);
    }

    if (!state.active) {
      const launcher = document.createElement("button");
      launcher.type = "button";
      launcher.className = "launcher";
      launcher.disabled = busy;
      launcher.setAttribute("data-branch-action", "fork");
      const dot = document.createElement("span");
      dot.className = "dot";
      launcher.append(dot, document.createTextNode(busy ? "Staging…" : "Stage branch"));
      launcher.addEventListener("click", () => runAction(() => api.fork("staging")));
      shadow.appendChild(launcher);
      return;
    }

    const edge = document.createElement("div");
    edge.className = "edge";
    edge.setAttribute("aria-hidden", "true");
    shadow.appendChild(edge);

    const banner = document.createElement("aside");
    banner.className = "banner";
    banner.setAttribute("role", "region");
    banner.setAttribute("aria-label", "Staging branch preview");

    const bar = document.createElement("div");
    bar.className = "bar";

    const meta = document.createElement("div");
    meta.className = "meta";

    const pill = document.createElement("span");
    pill.className = "pill";
    const dot = document.createElement("span");
    dot.className = "dot";
    pill.append(dot, document.createTextNode(`Staging · ${state.name}`));
    meta.appendChild(pill);

    const summary = document.createElement("span");
    summary.className = "summary";
    const breakdown = formatBreakdown(state.byOperation);
    summary.textContent = state.stagedCount > 0
      ? `${state.stagedCount} staged ${state.stagedCount === 1 ? "change" : "changes"}${breakdown ? ` (${breakdown})` : ""} · offline`
      : "0 staged changes · edits stay offline until approved";
    meta.appendChild(summary);

    if (state.mainDeltasDuringReview > 0) {
      const rebase = document.createElement("span");
      rebase.className = "pill pill-rebase";
      rebase.textContent = `+${state.mainDeltasDuringReview} on main (will rebase)`;
      meta.appendChild(rebase);
    }

    const actions = document.createElement("div");
    actions.className = "actions";

    if (state.stagedCount > 0) {
      const diffBtn = document.createElement("button");
      diffBtn.type = "button";
      diffBtn.className = "btn btn-diff";
      diffBtn.textContent = diffOpen ? "Hide diff" : "Inspect diff";
      diffBtn.addEventListener("click", () => {
        diffOpen = !diffOpen;
        render();
      });
      actions.appendChild(diffBtn);
    }

    const discardBtn = document.createElement("button");
    discardBtn.type = "button";
    discardBtn.className = "btn btn-discard";
    discardBtn.disabled = busy;
    discardBtn.setAttribute("data-branch-action", "discard");
    discardBtn.textContent = "Discard";
    discardBtn.addEventListener("click", () => {
      diffOpen = false;
      runAction(() => api.discard());
    });
    actions.appendChild(discardBtn);

    const approveBtn = document.createElement("button");
    approveBtn.type = "button";
    approveBtn.className = "btn btn-approve";
    approveBtn.disabled = busy;
    approveBtn.setAttribute("data-branch-action", "approve");
    approveBtn.textContent = busy ? "Replaying…" : "Approve & Sync";
    approveBtn.addEventListener("click", () => {
      diffOpen = false;
      runAction(() => api.approve({ conflict: "lww" }));
    });
    actions.appendChild(approveBtn);

    bar.append(meta, actions);
    banner.appendChild(bar);

    if (diffOpen && Array.isArray(state.mutations) && state.mutations.length > 0) {
      const diff = document.createElement("div");
      diff.className = "diff";
      const list = document.createElement("ul");
      for (const mutation of state.mutations) {
        const item = document.createElement("li");
        item.textContent = formatMutationSummary(mutation);
        list.appendChild(item);
      }
      diff.appendChild(list);
      banner.appendChild(diff);
    }

    shadow.appendChild(banner);
  }

  const onBranchChanged = (event) => {
    state = event.detail || { active: false };
    if (!state.active) diffOpen = false;
    if (state.lastAction) showNotice(formatOutcomeNotice(state.lastAction));
    render();
  };

  const onDomSwap = () => render();

  window.addEventListener("instant-record:branch-changed", onBranchChanged);
  window.addEventListener("instant-record:dom-written", onDomSwap);
  document.addEventListener("turbo:load", onDomSwap);
  render();

  return () => {
    clearTimeout(noticeTimer);
    window.removeEventListener("instant-record:branch-changed", onBranchChanged);
    window.removeEventListener("instant-record:dom-written", onDomSwap);
    document.removeEventListener("turbo:load", onDomSwap);
    hostEl?.remove();
  };
}
