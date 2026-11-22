import assert from "node:assert/strict"
import { test } from "node:test"
import { DEFAULT_CHUNK_SIZE, FileMissing, FileStore } from "./files.js"
import { fakeDisk, fakeServer } from "./test/fake-disk.js"

// A page's store: four bytes to a piece, so a short string is several.
const open = (disk, server, options = {}) => new FileStore({
  storage: disk.storage, fetch: server.fetch, locks: null, channel: null, pieceSize: 4, endpoint: "http://rails.test/instant_record",
  ...options,
})
const take = (bytes, type = "audio/wav") => new Blob([bytes], { type })
const text = async (blob) => blob && (await blob.text())

test("a file is here as soon as it is attached, and after a reload", async () => {
  const disk = fakeDisk()
  const server = fakeServer()
  const files = open(disk, server)

  const about = await files.attach("Clip", "one", new File(["a take of ten"], "take.wav", { type: "audio/wav" }))
  assert.deepEqual(about, { filename: "take.wav", content_type: "audio/wav", byte_size: 13 })

  const here = await files.get("Clip", "one")
  assert.equal(await text(here), "a take of ten")
  assert.equal(here.type, "audio/wav")
  assert.equal(here.name, "take.wav")

  const reloaded = open(disk, server)
  assert.equal(await text(await reloaded.get("Clip", "one")), "a take of ten")
  const stat = await reloaded.stat("Clip", "one")
  assert.equal(stat.local, true)
  assert.equal(stat.uploaded, false)
  assert.equal(stat.size, 13)
})

test("a file never changes: a second attach to the same record is refused", async () => {
  const files = open(fakeDisk(), fakeServer())
  await files.attach("Clip", "one", take("first"))

  await assert.rejects(files.attach("Clip", "one", take("second")), /already has a file/)
  assert.equal(await text(await files.get("Clip", "one")), "first")
  await assert.rejects(files.attach("Clip", "two", take("")), /needs bytes/)
})

test("what is not here is null, and asks nothing of the server", async () => {
  const server = fakeServer()
  const files = open(fakeDisk(), server)

  assert.equal(await files.get("Clip", "nowhere"), null)
  assert.equal(await files.stat("Clip", "nowhere"), null)
  assert.deepEqual(await files.list(), [])
  assert.equal(server.requests.length, 0)
})

test("an attached file goes to the server in pieces and is then marked as held there", async () => {
  const disk = fakeDisk()
  const server = fakeServer({ records: ["Clip/one"] })
  const files = open(disk, server)
  const seen = []
  files.subscribe((detail) => seen.push(detail.event))
  await files.attach("Clip", "one", take("a take of ten"))

  assert.deepEqual(await files.sync(), { sent: 1, waiting: 0 })

  assert.equal(await server.files.get("Clip/one").text(), "a take of ten")
  assert.deepEqual(server.asked("PUT").map((request) => request.offset), ["0", "4", "8", "12"])
  assert.equal((await files.stat("Clip", "one")).uploaded, true)
  assert.ok(seen.includes("added") && seen.includes("progress") && seen.includes("uploaded"))

  // Nothing is sent twice.
  const before = server.requests.length
  assert.deepEqual(await files.sync(), { sent: 0, waiting: 0 })
  assert.equal(server.requests.length, before)
})

test("a file attached before its record reached the server waits for it", async () => {
  const server = fakeServer()
  const files = open(fakeDisk(), server)
  await files.attach("Clip", "one", take("early bird"))

  assert.deepEqual(await files.sync(), { sent: 0, waiting: 1 })
  assert.equal(server.asked("PUT").length, 0, "nothing is sent for a record the server does not have")

  server.records.add("Clip/one")
  assert.deepEqual(await files.sync(), { sent: 1, waiting: 0 })
  assert.equal(await server.files.get("Clip/one").text(), "early bird")
})

test("with no connection the file waits, and nothing is lost", async () => {
  const disk = fakeDisk()
  const server = fakeServer({ records: ["Clip/one"] })
  server.offline = true
  const files = open(disk, server)
  await files.attach("Clip", "one", take("made offline"))

  assert.deepEqual(await files.sync(), { sent: 0, waiting: 1 })
  assert.equal(await text(await files.get("Clip", "one")), "made offline")

  server.offline = false
  assert.deepEqual(await open(disk, server).sync(), { sent: 1, waiting: 0 })
  assert.equal(await server.files.get("Clip/one").text(), "made offline")
})

test("an upload that was cut off goes on from the piece it stopped at", async () => {
  const disk = fakeDisk()
  const server = fakeServer({ records: ["Clip/one"] })
  const files = open(disk, server)
  await files.attach("Clip", "one", take("0123456789abcdef"))

  // The standing, two pieces, and then the connection goes.
  server.failAfter = 3
  assert.deepEqual(await files.sync(), { sent: 0, waiting: 1 })
  assert.equal((await files.stat("Clip", "one")).uploaded, false)

  server.failAfter = Infinity
  server.requests.length = 0
  assert.deepEqual(await open(disk, server).sync(), { sent: 1, waiting: 0 })
  assert.deepEqual(server.asked("PUT").map((request) => request.offset), ["8", "12"])
  assert.equal(await server.files.get("Clip/one").text(), "0123456789abcdef")
})

test("a piece the server already has is not an error: the upload moves to where the server is", async () => {
  const server = fakeServer({ records: ["Clip/one"] })
  const files = open(fakeDisk(), server)
  await files.attach("Clip", "one", take("0123456789"))
  // Another tab sent the first piece between this one asking and sending.
  const ask = server.fetch
  let raced = false
  server.fetch = async (url, options = {}) => {
    if (options.method === "PUT" && !raced) {
      raced = true
      await ask(url, options)
    }
    return ask(url, options)
  }

  assert.deepEqual(await open(fakeDiskOf(files), server).sync(), { sent: 1, waiting: 0 })
  assert.equal(await server.files.get("Clip/one").text(), "0123456789")
})

test("a file the server refuses is marked failed and is not sent again", async () => {
  const server = fakeServer({ records: ["Clip/one"], maxSize: 8 })
  const files = open(fakeDisk(), server)
  const failures = []
  files.subscribe((detail) => detail.event === "failed" && failures.push(detail.reason))
  await files.attach("Clip", "one", take("more than eight bytes"))

  assert.deepEqual(await files.sync(), { sent: 0, waiting: 1 })
  assert.deepEqual(failures, ["larger than this server takes"])
  assert.equal((await files.stat("Clip", "one")).failed, "larger than this server takes")

  const before = server.requests.length
  await files.sync()
  assert.equal(server.requests.length, before)
  assert.equal(await text(await files.get("Clip", "one")), "more than eight bytes", "the file is still here")
})

test("a file made on another device is fetched in pieces when it is opened, and kept", async () => {
  const disk = fakeDisk()
  const server = fakeServer()
  server.hold("Clip", "theirs", "from far away")
  const files = open(disk, server)
  const progress = []

  const file = await files.open("Clip", "theirs", { onProgress: (at) => progress.push(at.received) })

  assert.equal(await text(file), "from far away")
  assert.equal(file.type, "audio/wav")
  assert.deepEqual(server.asked("GET").map((request) => request.range), ["bytes=0-3", "bytes=4-7", "bytes=8-11", "bytes=12-12"])
  assert.deepEqual(progress, [4, 8, 12, 13])
  assert.deepEqual((await files.stat("Clip", "theirs")).uploaded, true)

  // Kept: the next open, and one with no connection after a reload, ask nothing.
  server.offline = true
  assert.equal(await text(await open(disk, server).open("Clip", "theirs")), "from far away")
})

test("two askers for one file share one fetch", async () => {
  const server = fakeServer()
  server.hold("Clip", "theirs", "from far away")
  const files = open(fakeDisk(), server)

  const [first, second] = await Promise.all([files.open("Clip", "theirs"), files.open("Clip", "theirs")])

  assert.equal(await text(first), "from far away")
  assert.equal(await text(second), "from far away")
  assert.equal(server.asked("HEAD").length, 1)
  assert.equal(server.asked("GET").length, 4)
})

test("a fetch that was cut off keeps its pieces and asks only for the rest", async () => {
  const disk = fakeDisk()
  const server = fakeServer()
  server.hold("Clip", "theirs", "0123456789abcdef")
  const files = open(disk, server)

  // The HEAD, two pieces, and then the connection goes.
  server.failAfter = 3
  await assert.rejects(files.open("Clip", "theirs"), /Failed to fetch/)
  assert.equal(await files.get("Clip", "theirs"), null, "half a file is no file")
  assert.equal((await files.stat("Clip", "theirs")).local, false)

  server.failAfter = Infinity
  server.requests.length = 0
  assert.equal(await text(await open(disk, server).open("Clip", "theirs")), "0123456789abcdef")
  assert.deepEqual(server.requests.map((request) => request.range), ["bytes=8-11", "bytes=12-15"])
})

test("a server that takes no ranges still gives the file", async () => {
  const server = fakeServer()
  server.ranges = false
  server.hold("Clip", "theirs", "0123456789")

  assert.equal(await text(await open(fakeDisk(), server).open("Clip", "theirs")), "0123456789")
})

test("a file the server does not hold is missing, and leaves nothing here", async () => {
  const disk = fakeDisk()
  const files = open(disk, fakeServer({ records: ["Clip/empty"] }))

  await assert.rejects(files.open("Clip", "empty"), FileMissing)
  await assert.rejects(files.open("Clip", "unknown"), (error) => error.name === "FileMissing")
  assert.equal(disk.used(), 0)
  assert.deepEqual(await files.list(), [])
})

test("past its budget the store drops what the server holds, least recently used first", async () => {
  const disk = fakeDisk()
  const server = fakeServer({ records: ["Clip/old", "Clip/older", "Clip/mine"] })
  const files = open(disk, server, { budget: 30 })
  const evicted = []
  files.subscribe((detail) => detail.event === "evicted" && evicted.push(detail.id))
  await files.attach("Clip", "older", take("0123456789"))
  await files.attach("Clip", "old", take("0123456789"))
  await files.sync()
  await files.attach("Clip", "mine", take("0123456789"))
  // Both of the first two are on the server. "old" was used a while after "older".
  await age(disk, "older", 3000)
  await age(disk, "old", 2000)

  await files.attach("Clip", "new", take("0123456789"))

  assert.deepEqual(evicted, ["older"])
  assert.equal(await files.get("Clip", "older"), null)
  assert.ok(await files.get("Clip", "old"))

  // It comes back when it is asked for, and the next least used makes room.
  assert.equal(await text(await files.open("Clip", "older")), "0123456789")
  assert.deepEqual(evicted, ["older", "old"])
})

test("a file the server does not hold, and a pinned one, are never dropped", async () => {
  const disk = fakeDisk()
  const server = fakeServer({ records: ["Clip/kept"] })
  const files = open(disk, server, { budget: 25 })
  await files.attach("Clip", "kept", take("0123456789"))
  await files.sync()
  await files.pin("Clip", "kept")
  await files.attach("Clip", "unsent", take("0123456789"))

  await assert.rejects(files.attach("Clip", "third", take("0123456789")), (error) => error.name === "QuotaExceededError")

  assert.ok(await files.get("Clip", "kept"))
  assert.ok(await files.get("Clip", "unsent"))
  assert.equal(await files.stat("Clip", "third"), null, "the file that did not fit left nothing behind")

  await files.unpin("Clip", "kept")
  await files.attach("Clip", "third", take("0123456789"))
  assert.equal(await files.get("Clip", "kept"), null)
})

test("near the browser's own limit, room is made the same way", async () => {
  const disk = fakeDisk({ quota: 2000 })
  const server = fakeServer({ records: ["Clip/sent"] })
  const files = open(disk, server, { headroom: 0.75, pieceSize: 256 })
  await files.attach("Clip", "sent", take("s".repeat(700)))
  await files.sync()
  assert.ok(disk.used() + 700 > 1500, "another 700 bytes would pass three quarters of what the browser allows")

  await files.attach("Clip", "next", take("n".repeat(700)))

  assert.equal(await files.get("Clip", "sent"), null)
  assert.ok(await files.get("Clip", "next"))
})

test("a disk that fills while a piece is written gets room made and one more try", async () => {
  const disk = fakeDisk()
  const server = fakeServer({ records: ["Clip/sent"] })
  const files = open(disk, server)
  await files.attach("Clip", "sent", take("0123456789abcdef"))
  await files.sync()
  // The browser gave no estimate, and the disk holds less than it seemed:
  // what is written beside a file, and two of this one's four pieces.
  disk.limit = disk.used() + (await metaSize(disk, "sent")) + 1 + 8

  await files.attach("Clip", "next", take("0123456789abcdef"))

  assert.equal(await text(await files.get("Clip", "next")), "0123456789abcdef")
  assert.equal(await files.get("Clip", "sent"), null, "the file the server holds went to make room")
})

test("a file there is no room to keep is still read, from the server", async () => {
  const disk = fakeDisk()
  const server = fakeServer()
  server.hold("Clip", "big", "0123456789abcdef")
  const files = open(disk, server, { budget: 8 })

  const file = await files.open("Clip", "big")

  assert.equal(await text(file), "0123456789abcdef")
  assert.equal(await files.stat("Clip", "big"), null)
  assert.equal(disk.used(), 0)
})

test("a browser with no private file system reads from the server and keeps nothing", async () => {
  const server = fakeServer()
  server.hold("Clip", "theirs", "from far away")
  const files = new FileStore({ storage: {}, fetch: server.fetch, locks: null, channel: null, endpoint: "http://rails.test/instant_record" })

  assert.equal(files.supported, false)
  assert.equal(await text(await files.open("Clip", "theirs")), "from far away")
  assert.equal(await files.get("Clip", "theirs"), null)
  assert.deepEqual(await files.list(), [])
  await assert.rejects(files.attach("Clip", "one", take("bytes")), /no private file system/)
})

test("remove, prune and clear drop files from here", async () => {
  const disk = fakeDisk()
  const files = open(disk, fakeServer())
  for (const id of ["a", "b", "c"]) await files.attach("Clip", id, take(`clip ${id}`))
  await files.attach("Cover", "a", take("a cover", "image/png"))

  await files.remove("Clip", "a")
  assert.equal(await files.get("Clip", "a"), null)
  assert.ok(await files.get("Cover", "a"), "another type's file of the same id stays")

  // The records that are left are b and (of covers) a.
  assert.equal(await files.prune("Clip", ["b"]), 1)
  assert.deepEqual((await files.list()).map((file) => `${file.type}/${file.id}`).sort(), ["Clip/b", "Cover/a"])

  assert.equal(await files.clear("Clip"), 1)
  assert.equal(await files.clear(), 1)
  assert.equal(disk.used(), 0)
})

test("what an interrupted attach left is not a file, and tidy removes it", async () => {
  const disk = fakeDisk()
  const files = open(disk, fakeServer())
  await files.attach("Clip", "whole", take("0123456789"))
  // The tab closed one piece into this one.
  const folder = await (await (await disk.root.getDirectoryHandle("instant-record-files")).getDirectoryHandle("type-Clip"))
    .getDirectoryHandle("torn", { create: true })
  await write(folder, "meta", JSON.stringify({ type: "Clip", id: "torn", size: 16, piece: 4, complete: false, uploaded: false }))
  await write(folder, "0", "0123")

  assert.equal(await files.get("Clip", "torn"), null)
  assert.equal(await files.stat("Clip", "torn"), null)
  assert.equal(await files.tidy(), 1)
  assert.deepEqual((await files.list()).map((file) => file.id), ["whole"])

  // The id is free again.
  await files.attach("Clip", "torn", take("whole now"))
  assert.equal(await text(await files.get("Clip", "torn")), "whole now")
})

test("usage says how much is here, how much is waiting, and what the browser allows", async () => {
  const disk = fakeDisk({ quota: 1000 })
  const server = fakeServer({ records: ["Clip/sent"] })
  const files = open(disk, server)
  await files.attach("Clip", "sent", take("0123456789"))
  await files.sync()
  await files.attach("Clip", "unsent", take("01234"))

  const usage = await files.usage()

  assert.equal(usage.files, 2)
  assert.equal(usage.bytes, 15)
  assert.equal(usage.waiting, 1)
  assert.equal(usage.waitingBytes, 5)
  assert.equal(usage.quota, 1000)
  assert.equal(usage.usage, disk.used())
  assert.equal(usage.persisted, true, "the first attach asked the browser to keep this origin's storage")
})

test("files of different accounts stay apart under a name", async () => {
  const disk = fakeDisk()
  const server = fakeServer()
  await open(disk, server, { name: "ada" }).attach("Clip", "one", take("ada's"))

  assert.equal(await open(disk, server, { name: "ben" }).get("Clip", "one"), null)
  assert.equal(await text(await open(disk, server, { name: "ada" }).get("Clip", "one")), "ada's")
})

test("an address names the type, the id and who is asking", () => {
  const files = open(fakeDisk(), fakeServer(), { scope: "browser token" })

  assert.equal(files.serverUrl("Mix::Stem", "a/b"), "http://rails.test/instant_record/files/Mix%3A%3AStem/a%2Fb?scope=browser+token")
})

test("who is asking goes with every request", async () => {
  const server = fakeServer({ records: ["Clip/one"] })
  const files = open(fakeDisk(), server, { scope: "token" })
  await files.attach("Clip", "one", take("0123"))
  await files.sync()

  assert.ok(server.requests.length > 0)
  assert.ok(server.requests.every((request) => request.scope === "token"))
})

test("default chunk size stays below 1 MB proxy limits and chunkSize is configurable", () => {
  assert.equal(DEFAULT_CHUNK_SIZE, 512 * 1024)
  assert.ok(DEFAULT_CHUNK_SIZE < 1024 * 1024)

  const defaults = new FileStore({ storage: fakeDisk().storage, fetch: fakeServer().fetch, locks: null, channel: null })
  assert.equal(defaults.chunkSize, DEFAULT_CHUNK_SIZE)
  assert.equal(defaults.pieceSize, DEFAULT_CHUNK_SIZE)

  const custom = new FileStore({ storage: fakeDisk().storage, fetch: fakeServer().fetch, locks: null, channel: null, chunkSize: 16384 })
  assert.equal(custom.chunkSize, 16384)
  assert.equal(custom.pieceSize, 16384)

  assert.throws(() => new FileStore({ chunkSize: 0 }), RangeError)
  assert.throws(() => new FileStore({ chunkSize: -4 }), RangeError)
  assert.throws(() => new FileStore({ chunkSize: 1.5 }), RangeError)
})

test("uploads and downloads adapt to a smaller server-advertised chunk size", async () => {
  const server = fakeServer({ records: ["Clip/one"], chunkSize: 3 })
  const files = open(fakeDisk(), server, { chunkSize: 8, pieceSize: undefined })
  await files.attach("Clip", "one", take("0123456789"))

  assert.deepEqual(await files.sync(), { sent: 1, waiting: 0 })
  assert.equal(await server.files.get("Clip/one").text(), "0123456789")
  assert.deepEqual(server.asked("PUT").map((request) => request.offset), ["0", "3", "6", "9"])

  // Download also respects x-instant-record-chunk-size from HEAD.
  server.requests.length = 0
  const other = open(fakeDisk(), server, { chunkSize: 8, pieceSize: undefined })
  assert.equal(await text(await other.open("Clip", "one")), "0123456789")
  assert.deepEqual(server.asked("GET").map((request) => request.range), ["bytes=0-2", "bytes=3-5", "bytes=6-8", "bytes=9-9"])
})

test("a 413 response with a smaller chunk_size shrinks upload pieces and succeeds", async () => {
  const server = fakeServer({ records: ["Clip/one"], chunkSize: 3, advertiseChunkSize: false })
  const files = open(fakeDisk(), server, { chunkSize: 8, pieceSize: undefined })
  await files.attach("Clip", "one", take("01234567"))

  assert.deepEqual(await files.sync(), { sent: 1, waiting: 0 })
  assert.equal(await server.files.get("Clip/one").text(), "01234567")
  assert.deepEqual(server.asked("PUT").map((request) => request.bodySize), [8, 3, 3, 2])
})

// The disk a store was opened on, for a second page over the same files.
function fakeDiskOf(store) {
  return { storage: store.storage }
}

async function write(folder, name, data) {
  const stream = await (await folder.getFileHandle(name, { create: true })).createWritable()
  await stream.write(data)
  await stream.close()
}

async function metaSize(disk, id) {
  const folder = await (await (await disk.root.getDirectoryHandle("instant-record-files")).getDirectoryHandle("type-Clip")).getDirectoryHandle(id)
  return (await (await folder.getFileHandle("meta")).getFile()).size
}

// Set a file's last use `ms` into the past.
async function age(disk, id, ms) {
  const folder = await (await (await disk.root.getDirectoryHandle("instant-record-files")).getDirectoryHandle("type-Clip")).getDirectoryHandle(id)
  const meta = JSON.parse(await (await (await folder.getFileHandle("meta")).getFile()).text())
  await write(folder, "meta", JSON.stringify({ ...meta, usedAt: meta.usedAt - ms }))
}
