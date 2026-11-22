// Version 3 fences out older workers that do not check the persisted schema.
let opened;
export function openSnapshot(partitionKey) {
  opened = new Promise((resolve, reject) => {
    const name = partitionKey ? "instant-record-spinel/partition/" + partitionKey : "instant-record-spinel";
    const request = indexedDB.open(name, 3);
    request.onupgradeneeded = event => {
      if (event.oldVersion === 0) request.result.createObjectStore("files");
    };
    request.onblocked = () => self.postMessage({ type: "storage_upgrade_blocked" });
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

// IndexedDB serializes readwrite transactions across workers. Only await
// requests from this transaction inside the callback, never network I/O.
export async function withFiles(mode, operation) {
  const db = await opened;
  return new Promise((resolve, reject) => {
    const tx = db.transaction("files", mode);
    const files = tx.objectStore("files");
    const get = key => new Promise((resolve, reject) => {
      const req = files.get(key);
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
    let result, failure;
    tx.oncomplete = () => resolve(result);
    tx.onabort = () => reject(failure || tx.error || new Error("Snapshot transaction aborted"));
    operation(get, (key, value) => files.put(value, key)).then(value => {
      result = value;
    }, error => {
      failure = error;
      try { tx.abort(); } catch { reject(error); }
    });
  });
}
