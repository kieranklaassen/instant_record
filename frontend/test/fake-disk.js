// What files.test.js stands a browser and a server on: the origin's private
// file system held in memory, and the gem's files endpoints as a `fetch`.

const notFound = (name) => new DOMException(`${name} was not found`, "NotFoundError")

class FakeFile {
  kind = "file"
  blob = new Blob([])

  constructor(disk) {
    this.disk = disk
  }

  async getFile() {
    return this.blob
  }

  // As the browser does it: nothing is in the file until the stream closes.
  async createWritable() {
    const parts = []
    return {
      write: async (data) => { parts.push(data) },
      close: async () => {
        const next = new Blob(parts)
        if (this.disk.used() - this.blob.size + next.size > this.disk.limit) {
          throw new DOMException("The disk is full", "QuotaExceededError")
        }
        this.blob = next
        this.disk.writes++
      },
      abort: async () => {},
    }
  }
}

class FakeFolder {
  kind = "directory"
  children = new Map()

  constructor(disk) {
    this.disk = disk
  }

  async getDirectoryHandle(name, { create = false } = {}) {
    return this.#child(name, create, FakeFolder)
  }

  async getFileHandle(name, { create = false } = {}) {
    return this.#child(name, create, FakeFile)
  }

  async removeEntry(name) {
    if (!this.children.delete(name)) throw notFound(name)
  }

  async *entries() {
    yield* [...this.children.entries()]
  }

  #child(name, create, kind) {
    if (!this.children.has(name)) {
      if (!create) throw notFound(name)
      this.children.set(name, new kind(this.disk))
    }
    return this.children.get(name)
  }

  bytes() {
    let sum = 0
    for (const child of this.children.values()) sum += child.kind === "file" ? child.blob.size : child.bytes()
    return sum
  }
}

// `navigator.storage`, with a limit a test can lower.
export function fakeDisk({ limit = Infinity, quota } = {}) {
  const disk = { limit, quota, writes: 0, persisted: false }
  disk.root = new FakeFolder(disk)
  disk.used = () => disk.root.bytes()
  disk.storage = {
    getDirectory: async () => disk.root,
    estimate: async () => (disk.quota ? { quota: disk.quota, usage: disk.used() } : {}),
    persist: async () => (disk.persisted = true),
    persisted: async () => disk.persisted,
  }
  return disk
}

const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } })

// The files endpoints, as FilesController answers them. `records` are the
// ids the server holds a record for; a file sent for any other is 404.
export function fakeServer({ records = [], maxSize = Infinity } = {}) {
  const server = {
    records: new Set(records), files: new Map(), partials: new Map(), requests: [], offline: false, failAfter: Infinity,
    ranges: true,
  }

  server.fetch = async (input, { method = "GET", headers = {}, body } = {}) => {
    const url = new URL(input)
    const [, type, id, tail] = url.pathname.match(/\/files\/([^/]+)\/([^/]+)(\/upload)?$/).map((part) => part && decodeURIComponent(part))
    const key = `${type}/${id}`
    const range = headers.Range || headers.range
    if (server.offline) throw new TypeError("Failed to fetch")
    server.requests.push({ method, key, upload: !!tail, range, offset: url.searchParams.get("offset"), scope: url.searchParams.get("scope") })
    if (server.requests.length > server.failAfter) throw new TypeError("Failed to fetch")

    if (tail || method === "PUT") {
      if (!server.records.has(key)) return new Response(null, { status: 404 })
      if (server.files.has(key)) return json({ complete: true, offset: server.files.get(key).size })
      const part = `${key}.${url.searchParams.get("upload")}`
      const held = server.partials.get(part) || new Blob([])
      if (tail) return json({ complete: false, offset: held.size })

      const size = Number(url.searchParams.get("size"))
      const offset = Number(url.searchParams.get("offset"))
      if (size > maxSize) return json({ error: "larger than this server takes" }, 413)
      if (offset !== held.size) return json({ complete: false, offset: held.size }, 409)
      const grown = new Blob([held, body])
      if (grown.size < size) {
        server.partials.set(part, grown)
        return json({ complete: false, offset: grown.size })
      }
      server.partials.delete(part)
      server.files.set(key, grown)
      return json({ complete: true, offset: grown.size })
    }

    const file = server.records.has(key) && server.files.get(key)
    if (!file) return new Response(null, { status: 404 })
    const about = { "content-type": file.type || "application/octet-stream", "content-length": String(file.size) }
    if (method === "HEAD") return new Response(null, { status: 200, headers: about })
    if (!range || !server.ranges) return new Response(file, { status: 200, headers: about })
    const [from, to] = range.replace("bytes=", "").split("-").map(Number)
    return new Response(file.slice(from, to + 1), { status: 206, headers: { ...about, "content-range": `bytes ${from}-${to}/${file.size}` } })
  }

  // A file the server already holds, with its record.
  server.hold = (type, id, bytes, contentType = "audio/wav") => {
    server.records.add(`${type}/${id}`)
    server.files.set(`${type}/${id}`, new Blob([bytes], { type: contentType }))
  }
  server.asked = (method) => server.requests.filter((request) => request.method === method && !request.upload)
  return server
}
