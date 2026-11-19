export const fetchHistoryViaWorker = (request) =>
  new Promise((resolve) => {
    const channel = new MessageChannel()
    // An unresponsive worker recovers on a later attempt; busy keeps the slot
    // idle instead of latching the offline notice.
    const timer = setTimeout(
      () => resolve({ ok: false, busy: true, error: "history request timed out" }),
      15000,
    )
    channel.port1.onmessage = (event) => {
      clearTimeout(timer)
      resolve(event.data || { ok: false, error: "empty reply" })
    }
    const worker = window.__spinel.worker
    worker.postMessage(
      { type: "instant_record.fetch_history", request },
      [channel.port2],
    )
  })
