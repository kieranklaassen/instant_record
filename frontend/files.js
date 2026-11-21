// A record's file, kept in the browser.
//
// A model that declares `sync_file` has records that carry a file: bytes too
// large for a column (a recording, a render). The record syncs as any other
// does. Its bytes are kept here, in the origin's private file system, where
// they are at hand with no connection:
//
//   import { fileStore } from "instant_record"
//   const files = fileStore()
//
//   const id = crypto.randomUUID()
//   const about = await files.attach("Recording", id, blob)   // written here first
//   // ...create the record with that id; `about` is { filename, content_type, byte_size }
//
//   const file = await files.open("Recording", id)            // here, or fetched and kept
//
// A file written here is sent to the server in the background, in pieces, and
// goes on from where it stopped after a reload or a lost connection. A file
// made on another device is fetched when it is asked for, a piece at a time,
// and kept. A file never changes: new bytes are a new record.
//
// Room is the browser's to give. A file the server holds can be fetched
// again, so it may be dropped here to make room, least recently used first. A
// file the server does not hold yet is never dropped, and neither is a pinned
// one. Nothing here needs a local database: beside the compiled runtime and on
// a page Rails serves it does the same thing.

const ROOT = "instant-record-files"
const META = "meta"
const PIECE = 4 * 1024 * 1024
const CHANGED = "instant-record:records-changed"
const RETRY_BASE_MS = 2000
const RETRY_CAP_MS = 60000
// What `usedAt` is good for is an order, so it is not rewritten on every read.
const TOUCH_MS = 60000

// The server does not hold the file: its record has not reached it, the
// upload has not finished, or the asker may not see it.
export class FileMissing extends Error {
  constructor(type, id) {
    super(`${type} ${id} has no file on the server`)
    this.name = "FileMissing"
  }
}

// No room for the bytes, after everything that may be dropped was.
export class NoRoom extends Error {
  constructor(bytes) {
    super(`No room to keep ${bytes} bytes`)
    this.name = "QuotaExceededError"
    this.bytes = bytes
  }
}

const safe = (name) => encodeURIComponent(String(name)).replace(/^\./, "%2E")
const token = () => (globalThis.crypto?.randomUUID?.() || `${Date.now()}-${Math.random()}`).replace(/[^\w-]/g, "")
const full = (error) => error?.name === "QuotaExceededError"
const missing = (error) => error?.name === "NotFoundError"

async function entries(folder) {
  const found = []
  for await (const [name, handle] of folder.entries()) found.push([name, handle])
  return found
}

export class FileStore {
  #root = null
  #listeners = new Set()
  #downloads = new Map()
  #chains = new Map()
  #syncing = null
  #again = false
  #timer = null
  #retryMs = RETRY_BASE_MS
  #stops = []
  #asked = false

  constructor(options = {}) {
    const page = typeof window === "undefined" ? {} : window.__spinel || {}
    this.endpoint = String(options.endpoint ?? page.endpoint ?? "/instant_record").replace(/\/$/, "")
    // Who is asking, for a server that reads it from a `scope` parameter. A
    // server that reads its session gets the cookie instead.
    this.scope = options.scope ?? page.scope ?? ""
    // Files of different accounts in one browser stay apart under a name.
    this.name = options.name ? safe(options.name) : ""
    this.pieceSize = options.pieceSize || PIECE
    // The most bytes to hold here. Past it, or near the browser's own limit,
    // files the server holds are dropped to make room.
    this.budget = options.budget ?? Infinity
    this.headroom = options.headroom ?? 0.9
    this.persistent = options.persist ?? true
    this.storage = options.storage ?? globalThis.navigator?.storage
    this.locks = options.locks === undefined ? globalThis.navigator?.locks : options.locks
    this.fetch = options.fetch ?? ((...args) => globalThis.fetch(...args))
    this.channel = options.channel === undefined && typeof BroadcastChannel !== "undefined"
      ? new BroadcastChannel(`${ROOT}/${this.name}`)
      : options.channel || null
    if (this.channel) this.channel.onmessage = (event) => this.#tell({ ...event.data, remote: true })
  }

  // True where the browser has a private file system that can be written from
  // a page. Without one, `open` still reads from the server and keeps nothing.
  get supported() {
    return typeof this.storage?.getDirectory === "function"
  }

  // ── writing ────────────────────────────────────────────────────────────────

  // Keep `blob` as the file of the record `type`/`id`, and queue it for the
  // server. Answers what a record says about its file, under the names an
  // Active Storage blob uses, for the form that creates the record.
  async attach(type, id, blob, { name, contentType, pinned = false } = {}) {
    if (!blob?.size) throw new TypeError("A file needs bytes")
    if (!this.supported) throw new Error("This browser has no private file system to keep a file in")
    if (this.persistent && !this.#asked) {
      this.#asked = true
      this.persist()
    }
    const meta = {
      type: String(type), id: String(id), name: name ?? blob.name ?? "", contentType: contentType ?? blob.type ?? "",
      size: blob.size, piece: this.pieceSize, upload: token(), complete: false, uploaded: false, pinned,
      addedAt: Date.now(), usedAt: Date.now(),
    }
    await this.#locked(meta, async () => {
      if (await this.#meta(type, id)) throw new Error(`${type} ${id} already has a file. A new file is a new record.`)
      await this.#room(meta, meta.size)
      try {
        // Whatever an interrupted attach left here is not part of this file.
        await this.#drop(meta)
        const folder = await this.#folder(type, id, true)
        await this.#write(folder, META, JSON.stringify(meta))
        for (let index = 0; index * meta.piece < meta.size; index++) {
          await this.#piece(folder, index, blob.slice(index * meta.piece, (index + 1) * meta.piece), meta)
        }
        meta.complete = true
        await this.#write(folder, META, JSON.stringify(meta))
      } catch (error) {
        await this.#drop(meta)
        throw full(error) ? new NoRoom(blob.size) : error
      }
    })
    this.#announce("added", meta)
    this.sync()
    return { filename: meta.name, content_type: meta.contentType, byte_size: meta.size }
  }

  // ── reading ────────────────────────────────────────────────────────────────

  // The file if it is here, else null. Asks nothing of the server.
  async get(type, id, { touch = true } = {}) {
    const meta = await this.#meta(type, id)
    if (!meta?.complete) return null
    try {
      const folder = await this.#folder(type, id)
      const parts = []
      for (let index = 0; index * meta.piece < meta.size; index++) {
        parts.push(await (await folder.getFileHandle(String(index))).getFile())
      }
      if (touch && Date.now() - meta.usedAt > TOUCH_MS) {
        this.#write(folder, META, JSON.stringify({ ...meta, usedAt: Date.now() })).catch(() => {})
      }
      return new File(parts, meta.name || meta.id, { type: meta.contentType })
    } catch (error) {
      if (!missing(error)) throw error
      // A piece is gone: the browser cleared it, or another tab is dropping
      // the file. What is left is no file.
      return null
    }
  }

  // The file: from here, or fetched from the server and kept. Throws
  // FileMissing when the server does not hold it, and whatever `fetch` throws
  // when there is no connection.
  async open(type, id, options = {}) {
    return (await this.get(type, id)) || this.download(type, id, options)
  }

  // An address for an <audio> or an <img>. The caller revokes it.
  async url(type, id, options) {
    return URL.createObjectURL(await this.open(type, id, options))
  }

  // Fetch a file from the server and keep it, as `open` does for one that is
  // not here: a piece at a time, going on from the pieces already held.
  // `onProgress` is told { received, size }.
  download(type, id, { onProgress, signal } = {}) {
    const key = `${type}/${id}`
    if (!this.#downloads.has(key)) {
      const fetching = this.#download(String(type), String(id), onProgress, signal)
        .finally(() => this.#downloads.delete(key))
      this.#downloads.set(key, fetching)
    }
    return this.#downloads.get(key)
  }

  // ── what is here ───────────────────────────────────────────────────────────

  // What is known here about a record's file, or null: { type, id, name,
  // contentType, size, local, uploaded, pinned, failed, addedAt, usedAt }.
  // `local` says the whole file is here. `uploaded` says the server holds it.
  async stat(type, id) {
    const meta = await this.#meta(type, id)
    return meta && this.#shown(meta)
  }

  async list() {
    return (await this.#metas()).map((meta) => this.#shown(meta))
  }

  // How much is held and how much room there is: { files, bytes, waiting,
  // waitingBytes, quota, usage, persisted }. `waiting` counts the files the
  // server does not hold yet. `quota` and `usage` are the browser's estimate
  // for the whole origin, null where it gives none.
  async usage() {
    const metas = await this.#metas()
    const held = metas.filter((meta) => meta.complete)
    const waiting = held.filter((meta) => !meta.uploaded)
    const estimate = await this.#estimate()
    return {
      files: held.length,
      // A file that is half fetched counts whole: its room is spoken for.
      bytes: metas.reduce((sum, meta) => sum + meta.size, 0),
      waiting: waiting.length,
      waitingBytes: waiting.reduce((sum, meta) => sum + meta.size, 0),
      quota: estimate.quota ?? null,
      usage: estimate.usage ?? null,
      persisted: (await this.storage?.persisted?.().catch(() => false)) ?? false,
    }
  }

  // Ask the browser not to clear this origin's storage when the disk fills.
  // Without it a browser short of room may drop everything, files the server
  // never received among them. Answers whether it agreed.
  async persist() {
    try {
      return (await this.storage?.persist?.()) ?? false
    } catch {
      return false
    }
  }

  // ── keeping and dropping ───────────────────────────────────────────────────

  // A pinned file is never dropped to make room.
  pin(type, id) { return this.#mark(type, id, { pinned: true }) }
  unpin(type, id) { return this.#mark(type, id, { pinned: false }) }

  // Drop a file from here, whether or not the server holds it.
  async remove(type, id) {
    const meta = (await this.#meta(type, id)) || { type: String(type), id: String(id) }
    await this.#locked(meta, () => this.#drop(meta))
    this.#announce("removed", meta)
  }

  // Drop the files of `type` whose records are gone: every one whose id is
  // not in `ids`. A page that has the list of records calls this with it.
  async prune(type, ids) {
    const kept = new Set([...ids].map(String))
    const gone = (await this.#metas()).filter((meta) => meta.type === String(type) && !kept.has(meta.id))
    for (const meta of gone) await this.remove(meta.type, meta.id)
    return gone.length
  }

  // Drop everything, or every file of one type: for a sign-out.
  async clear(type) {
    const gone = (await this.#metas()).filter((meta) => type === undefined || meta.type === String(type))
    for (const meta of gone) await this.remove(meta.type, meta.id)
    return gone.length
  }

  // Make room for `bytes` by dropping files the server holds, least recently
  // used first. Answers how many bytes went.
  free(bytes) {
    return this.#evict(bytes, null)
  }

  // ── sending ────────────────────────────────────────────────────────────────

  // Send the files the server does not hold yet. One pass runs at a time, in
  // one tab at a time, and a call made during a pass makes it go round again.
  // Answers { sent, waiting }: `waiting` files were not taken, because their
  // record has not reached the server or the connection dropped.
  sync() {
    if (this.#syncing) {
      this.#again = true
      return this.#syncing
    }
    this.#syncing = (async () => {
      let result = { sent: 0, waiting: 0 }
      do {
        this.#again = false
        const pass = await this.#exclusive("upload", () => this.#drain(), { ifAvailable: true })
        // Another tab is sending. It is asked to look again when it is done,
        // and this one looks again later in case that tab is closed first.
        if (!pass) {
          this.channel?.postMessage({ event: "sync" })
          this.#later(1)
        } else result = { sent: result.sent + pass.sent, waiting: pass.waiting }
      } while (this.#again)
      return result
    })().finally(() => { this.#syncing = null })
    return this.#syncing
  }

  // Send what is waiting whenever it may get through: now, when the
  // connection returns, when the local database changes (a record may have
  // reached the server), and after a wait that lengthens while nothing does.
  start() {
    if (this.#stops.length || typeof window === "undefined") return this
    const kick = () => { this.#retryMs = RETRY_BASE_MS; this.sync() }
    for (const name of ["online", CHANGED]) {
      window.addEventListener(name, kick)
      this.#stops.push(() => window.removeEventListener(name, kick))
    }
    this.#stops.push(this.subscribe((detail) => {
      if (detail.event === "sync" && detail.remote) this.sync()
      // After a pass, come back for whatever it left.
      if (detail.event === "synced" && !detail.remote) this.#later(detail.waiting)
    }))
    this.tidy().then(kick, kick)
    return this
  }

  stop() {
    clearTimeout(this.#timer)
    this.#timer = null
    for (const stop of this.#stops.splice(0)) stop()
  }

  // Told of everything that happens to a file, here or in another tab:
  // { event, type, id, ... } where event is added, progress, uploaded, failed,
  // fetched, evicted or removed. Answers a function that stops the telling.
  subscribe(listener) {
    this.#listeners.add(listener)
    return () => this.#listeners.delete(listener)
  }

  // Remove what an interrupted `attach` left: pieces of a file that was never
  // whole and that the server never had.
  async tidy() {
    const dead = (await this.#metas({ torn: true })).filter((meta) => !meta.complete && !meta.uploaded)
    for (const meta of dead) {
      await this.#locked(meta, async () => {
        const now = await this.#meta(meta.type, meta.id, { torn: true })
        if (!now || (!now.complete && !now.uploaded)) await this.#drop(meta)
      }, { ifAvailable: true })
    }
    return dead.length
  }

  // The file's address on the server.
  serverUrl(type, id, params = {}, path = "") {
    const url = new URL(`${this.endpoint}/files/${encodeURIComponent(type)}/${encodeURIComponent(id)}${path}`,
      globalThis.location?.href || "http://localhost")
    if (this.scope) url.searchParams.set("scope", this.scope)
    for (const [key, value] of Object.entries(params)) url.searchParams.set(key, String(value))
    return url.href
  }

  // ── inside ─────────────────────────────────────────────────────────────────

  async #download(type, id, onProgress, signal) {
    if (!this.supported) return this.#whole(type, id, signal)
    const lock = { type, id }
    let unkept = false
    const fetched = await this.#locked(lock, async () => {
      // Another tab may have fetched it while this one waited.
      const here = await this.get(type, id)
      if (here) return here

      // Pieces of a fetch that was cut off are kept and built on. Anything
      // else that is here is not this file: the server is asked afresh.
      let meta = await this.#meta(type, id)
      if (!meta?.uploaded || meta.complete) {
        const head = await this.#ask(this.serverUrl(type, id), { method: "HEAD", signal })
        if (head.status === 404) throw new FileMissing(type, id)
        if (!head.ok) throw new Error(`The server answered ${head.status} for ${type} ${id}`)
        await this.#drop({ type, id })
        meta = {
          type, id, name: "", contentType: head.headers.get("content-type") || "",
          size: Number(head.headers.get("content-length")), piece: this.pieceSize, upload: null,
          complete: false, uploaded: true, pinned: false, addedAt: Date.now(), usedAt: Date.now(),
        }
        if (!(meta.size > 0)) throw new Error(`The server gave no size for ${type} ${id}`)
      }
      try {
        const folder = await this.#folder(type, id, true)
        const held = await this.#held(folder, meta)
        await this.#room(meta, meta.size - held.length * meta.piece)
        await this.#write(folder, META, JSON.stringify(meta))
        for (let index = 0; index * meta.piece < meta.size; index++) {
          const from = index * meta.piece
          const to = Math.min(from + meta.piece, meta.size) - 1
          if (!held.includes(index)) {
            const reply = await this.#ask(this.serverUrl(type, id), { headers: { Range: `bytes=${from}-${to}` }, signal })
            if (reply.status === 404) throw new FileMissing(type, id)
            if (!reply.ok) throw new Error(`The server answered ${reply.status} for ${type} ${id}`)
            let piece = await reply.blob()
            // A server that takes no ranges sends the whole file every time.
            if (reply.status === 200 && piece.size === meta.size) piece = piece.slice(from, to + 1)
            if (piece.size !== to - from + 1) throw new Error(`A piece of ${type} ${id} arrived the wrong size`)
            await this.#piece(folder, index, piece, meta)
          }
          onProgress?.({ received: to + 1, size: meta.size })
          this.#tell({ event: "progress", type, id, received: to + 1, size: meta.size })
        }
        meta.complete = true
        await this.#write(folder, META, JSON.stringify(meta))
        return this.get(type, id, { touch: false })
      } catch (error) {
        if (!full(error)) throw error
        // No room for it even after dropping what could go: the pieces are
        // given back, and the file is read without being kept.
        await this.#drop(meta)
        unkept = true
      }
    })
    if (unkept) return this.#whole(type, id, signal)
    this.#announce("fetched", lock)
    return fetched
  }

  // The file read straight from the server, into memory, and not kept.
  async #whole(type, id, signal) {
    const reply = await this.#ask(this.serverUrl(type, id), { signal })
    if (reply.status === 404) throw new FileMissing(type, id)
    if (!reply.ok) throw new Error(`The server answered ${reply.status} for ${type} ${id}`)
    const blob = await reply.blob()
    return new File([blob], String(id), { type: reply.headers.get("content-type") || blob.type })
  }

  async #drain() {
    const waiting = (await this.#metas())
      .filter((meta) => meta.complete && !meta.uploaded && !meta.failed)
      .sort((a, b) => a.addedAt - b.addedAt)
    let sent = 0
    let left = 0
    for (const meta of waiting) {
      try {
        (await this.#send(meta)) ? sent++ : left++
      } catch {
        // No connection, or a server in trouble: the rest wait with this one.
        left = waiting.length - sent
        break
      }
    }
    this.#tell({ event: "synced", sent, waiting: left })
    return { sent, waiting: left }
  }

  // One file to the server, from wherever its upload stands. Answers whether
  // the server now holds it.
  async #send(meta) {
    const blob = await this.get(meta.type, meta.id, { touch: false })
    if (!blob) return false
    const standing = await this.#ask(this.serverUrl(meta.type, meta.id, { upload: meta.upload }, "/upload"))
    // The record has not reached the server yet. It goes up with the next
    // sync pass, and this is asked again after it.
    if (standing.status === 404) return false
    if (!standing.ok) throw new Error(`The server answered ${standing.status}`)
    let { complete, offset } = await standing.json()

    for (let turns = 0; !complete; turns++) {
      // Every turn moves the offset forward. One that does not is a server
      // and a browser that disagree, which no number of tries will settle.
      if (turns > Math.ceil(meta.size / this.pieceSize) + 8) throw new Error("The upload is not moving")
      const reply = await this.#ask(this.serverUrl(meta.type, meta.id, { upload: meta.upload, offset, size: meta.size }), {
        method: "PUT", headers: { "content-type": "application/octet-stream" },
        body: blob.slice(offset, offset + this.pieceSize),
      })
      if (reply.status === 404) return false
      if (reply.status === 409) {
        offset = (await reply.json()).offset
        continue
      }
      if ([400, 413, 415, 422].includes(reply.status)) {
        // The server will not take this file however often it is sent.
        const failed = (await reply.json().catch(() => ({}))).error || `refused (${reply.status})`
        await this.#mark(meta.type, meta.id, { failed })
        this.#announce("failed", meta, { reason: failed })
        return false
      }
      if (!reply.ok) throw new Error(`The server answered ${reply.status}`)
      ;({ complete, offset } = await reply.json())
      this.#tell({ event: "progress", type: meta.type, id: meta.id, sent: offset, size: meta.size })
    }
    await this.#mark(meta.type, meta.id, { uploaded: true })
    this.#announce("uploaded", meta)
    return true
  }

  #later(waiting) {
    clearTimeout(this.#timer)
    this.#timer = null
    if (!waiting || !this.#stops.length) {
      this.#retryMs = RETRY_BASE_MS
      return
    }
    this.#timer = setTimeout(() => this.sync(), this.#retryMs)
    this.#retryMs = Math.min(this.#retryMs * 2, RETRY_CAP_MS)
  }

  async #ask(url, { signal, ...options } = {}) {
    const limit = typeof AbortSignal !== "undefined" && AbortSignal.timeout ? AbortSignal.timeout(120000) : undefined
    const both = signal && limit && AbortSignal.any ? AbortSignal.any([signal, limit]) : signal || limit
    return this.fetch(url, { credentials: "same-origin", ...options, signal: both })
  }

  // Room for the file `keep`, which has `bytes` still to write: inside this
  // store's budget, and inside what the browser says the origin may hold.
  async #room(keep, bytes) {
    if (bytes <= 0) return
    const estimate = await this.#estimate()
    const others = (await this.#metas({ torn: true }))
      .filter((meta) => !(meta.type === keep.type && meta.id === keep.id))
      .reduce((sum, meta) => sum + meta.size, 0)
    const over = Math.max(
      others + keep.size - this.budget,
      estimate.quota ? (estimate.usage || 0) + bytes - estimate.quota * this.headroom : 0,
    )
    if (over > 0 && (await this.#evict(over, keep)) < over) throw new NoRoom(bytes)
  }

  async #evict(bytes, keep) {
    const droppable = (await this.#metas())
      .filter((meta) => meta.uploaded && !meta.pinned && !(keep && meta.type === keep.type && meta.id === keep.id))
      // A file that is half fetched goes before a whole one.
      .sort((a, b) => Number(a.complete) - Number(b.complete) || a.usedAt - b.usedAt)
    let freed = 0
    for (const meta of droppable) {
      if (freed >= bytes) break
      if (this.#downloads.has(`${meta.type}/${meta.id}`)) continue
      const dropped = await this.#locked(meta, async () => {
        await this.#drop(meta)
        return true
      }, { ifAvailable: true })
      if (!dropped) continue
      freed += meta.size
      this.#announce("evicted", meta)
    }
    return freed
  }

  async #estimate() {
    try {
      return (await this.storage?.estimate?.()) || {}
    } catch {
      return {}
    }
  }

  // A piece is written whole or not at all: the browser swaps it in when the
  // stream closes. A disk that fills on the way gets one more try, after
  // dropping what may go.
  async #piece(folder, index, blob, keep) {
    try {
      await this.#write(folder, String(index), blob)
    } catch (error) {
      if (!full(error) || (await this.#evict(blob.size, keep)) < blob.size) throw error
      await this.#write(folder, String(index), blob)
    }
  }

  async #write(folder, name, data) {
    const handle = await folder.getFileHandle(name, { create: true })
    const stream = await handle.createWritable()
    try {
      await stream.write(data)
      await stream.close()
    } catch (error) {
      await stream.abort?.().catch(() => {})
      throw error
    }
  }

  // The indexes of the pieces already here.
  async #held(folder, meta) {
    const held = []
    for (const [name] of await entries(folder)) {
      const index = Number(name)
      if (name !== META && Number.isInteger(index) && index * meta.piece < meta.size) held.push(index)
    }
    return held
  }

  async #mark(type, id, change) {
    const lock = { type: String(type), id: String(id) }
    return this.#locked(lock, async () => {
      const meta = await this.#meta(type, id)
      if (!meta) return false
      await this.#write(await this.#folder(type, id), META, JSON.stringify({ ...meta, ...change }))
      return true
    })
  }

  async #drop({ type, id }) {
    try {
      const parent = await this.#folder(type)
      await parent?.removeEntry(safe(id), { recursive: true })
    } catch (error) {
      if (!missing(error)) throw error
    }
  }

  async #top() {
    if (!this.supported) return null
    if (!this.#root) {
      this.#root = (async () => {
        const origin = await this.storage.getDirectory()
        const root = await origin.getDirectoryHandle(ROOT, { create: true })
        return this.name ? root.getDirectoryHandle(`name-${this.name}`, { create: true }) : root
      })()
      this.#root.catch(() => { this.#root = null })
    }
    return this.#root
  }

  // The folder of a type, or of one record's file in it. Null when it is not
  // there and is not to be made.
  async #folder(type, id, create = false) {
    try {
      const top = await this.#top()
      const types = await top?.getDirectoryHandle(`type-${safe(type)}`, { create })
      return id === undefined ? types : await types?.getDirectoryHandle(safe(id), { create })
    } catch (error) {
      if (missing(error)) return null
      throw error
    }
  }

  // What is written beside a file's pieces. `torn` also answers for one that
  // an interrupted attach left; nothing else looks at those.
  async #meta(type, id, { torn = false } = {}) {
    const folder = await this.#folder(type, id)
    return folder ? this.#read(folder, torn) : null
  }

  async #read(folder, torn) {
    try {
      const meta = JSON.parse(await (await (await folder.getFileHandle(META)).getFile()).text())
      return torn || meta.complete || meta.uploaded ? meta : null
    } catch (error) {
      if (missing(error) || error instanceof SyntaxError) return null
      throw error
    }
  }

  async #metas({ torn = false } = {}) {
    const top = await this.#top()
    if (!top) return []
    const metas = []
    for (const [name, types] of await entries(top)) {
      if (types.kind !== "directory" || !name.startsWith("type-")) continue
      for (const [, folder] of await entries(types)) {
        const meta = folder.kind === "directory" && (await this.#read(folder, torn))
        if (meta) metas.push(meta)
      }
    }
    return metas
  }

  #shown(meta) {
    return {
      type: meta.type, id: meta.id, name: meta.name, contentType: meta.contentType, size: meta.size,
      local: meta.complete, uploaded: meta.uploaded, pinned: meta.pinned, failed: meta.failed || null,
      addedAt: meta.addedAt, usedAt: meta.usedAt,
    }
  }

  #announce(event, { type, id }, more = {}) {
    const detail = { event, type, id, ...more }
    this.channel?.postMessage(detail)
    this.#tell(detail)
  }

  #tell(detail) {
    for (const listener of this.#listeners) listener(detail)
  }

  // One writer at a time for a file, across the tabs of this origin where the
  // browser has locks and within this page where it has none.
  #locked({ type, id }, work, options) {
    return this.#exclusive(`file/${safe(type)}/${safe(id)}`, work, options)
  }

  #exclusive(name, work, { ifAvailable = false } = {}) {
    const key = `${ROOT}/${this.name}/${name}`
    if (this.locks) {
      return this.locks.request(key, { ifAvailable }, (lock) => (lock ? work() : undefined))
    }
    const before = this.#chains.get(key)
    if (before && ifAvailable) return Promise.resolve(undefined)
    const run = (before || Promise.resolve()).catch(() => {}).then(work)
    const settled = run.catch(() => {}).finally(() => {
      if (this.#chains.get(key) === settled) this.#chains.delete(key)
    })
    this.#chains.set(key, settled)
    return run
  }
}

// One store for the page. Its uploads start with it.
export function fileStore(options = {}) {
  const store = new FileStore(options)
  return options.auto === false ? store : store.start()
}
