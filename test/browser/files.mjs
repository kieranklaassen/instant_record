// The file store in a real browser against a real Rails server: a record's
// file written with the sync server out of reach, kept across a reload, sent
// in pieces, fetched on another device, dropped to make room and fetched
// again.
//
//   node test/browser/files.mjs          (add --big for a 200 MB file, timed)
//
// It starts test/browser/files_app.ru under the gem's own bundle and drives
// Chromium through Playwright, found where PLAYWRIGHT_NODE_MODULES says or
// wherever node resolves it. Each browser context is one device.
import assert from "node:assert/strict"
import { spawn } from "node:child_process"
import { createHash } from "node:crypto"
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs"
import { createRequire } from "node:module"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const gem = join(dirname(fileURLToPath(import.meta.url)), "../..")
const find = createRequire(process.env.PLAYWRIGHT_NODE_MODULES ? process.env.PLAYWRIGHT_NODE_MODULES + "/" : import.meta.url)
const { chromium } = find("playwright-core")

const PORT = Number(process.env.FILES_APP_PORT || 3220)
const ORIGIN = `http://127.0.0.1:${PORT}`
const MB = 1024 * 1024
const PIECE = 512 * 1024
const offsets = (bytes, start = 0) => Array.from({ length: Math.ceil((bytes - start) / PIECE) }, (_, i) => start + i * PIECE)
const byteRanges = (bytes, start = 0) => offsets(bytes, start).map((from) => `bytes=${from}-${Math.min(from + PIECE, bytes) - 1}`)
const root = mkdtempSync(join(tmpdir(), "instant-record-files-app-"))
const kept = (id) => join(root, "storage/instant_record/clip", id)
const sha = (bytes) => createHash("sha256").update(bytes).digest("hex")

const server = spawn("bundle", ["exec", "puma", "-p", String(PORT), "-e", "development", "--quiet", "test/browser/files_app.ru"],
  { cwd: gem, env: { ...process.env, FILES_APP_ROOT: root }, stdio: ["ignore", "ignore", "inherit"] })
const up = async () => {
  for (let tries = 0; tries < 150; tries++) {
    try { if ((await fetch(ORIGIN + "/")).ok) return } catch {}
    await new Promise((resolve) => setTimeout(resolve, 200))
  }
  throw new Error("the Rails app did not come up")
}

let browser
const pageErrors = []
const passed = []
const step = async (name, run) => {
  const started = Date.now()
  await run()
  passed.push(name)
  console.log(`✓ ${name} (${Date.now() - started} ms)`)
}

// One device: a browser context with its own storage, and what it asked of
// the files endpoints. `net.down` puts the sync server out of reach while the
// page itself still loads; `net.cut` drops the connection once that many
// requests of one method have gone to the files endpoints.
async function device(query = "scope=ada") {
  const context = await browser.newContext()
  const net = { down: false, cut: null, asked: [] }
  await context.route("**/instant_record/**", (route) => {
    const request = route.request()
    const url = new URL(request.url())
    const file = url.pathname.includes("/files/")
    const entry = { method: request.method(), path: url.pathname, offset: url.searchParams.get("offset"),
      range: request.headers().range || null, upload: url.pathname.endsWith("/upload") }
    if (net.down) return route.abort("internetdisconnected")
    if (file && net.cut && net.cut.method === entry.method && !entry.upload) {
      if (net.cut.after-- <= 0) return route.abort("internetdisconnected")
    }
    if (file) net.asked.push(entry)
    return route.continue()
  })
  const page = await context.newPage()
  page.on("pageerror", (error) => pageErrors.push(error.message))
  await open(page, query)
  return { context, page, net }
}

async function open(page, query = "scope=ada") {
  await page.goto(`${ORIGIN}/?${query}`)
  await page.waitForFunction(() => window.ready)
}

// Random bytes made in the page, kept there as window.made[id]. Answers their
// SHA-256.
const make = (page, id, bytes) => page.evaluate(async ({ id, bytes }) => {
  const parts = []
  for (let left = bytes; left > 0; left -= 65536) parts.push(crypto.getRandomValues(new Uint8Array(Math.min(left, 65536))))
  window.made ||= {}
  window.made[id] = new File(parts, `${id}.bin`, { type: "application/octet-stream" })
  const digest = await crypto.subtle.digest("SHA-256", await window.made[id].arrayBuffer())
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("")
}, { id, bytes })

const digestOf = (page, id, how = "get") => page.evaluate(async ({ id, how }) => {
  const file = await window.files[how]("Clip", id)
  if (!file) return null
  const digest = await crypto.subtle.digest("SHA-256", await file.arrayBuffer())
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("")
}, { id, how })

const attach = (page, id) => page.evaluate((id) => window.files.attach("Clip", id, window.made[id]), id)
const sync = (page) => page.evaluate(() => window.files.sync())
const stat = (page, id) => page.evaluate((id) => window.files.stat("Clip", id), id)
const failure = (page, id, how = "open") => page.evaluate(({ id, how }) => window.files[how]("Clip", id).then(() => null, (error) => error.name), { id, how })

// The record, as the sync client sends it: through the mutations endpoint.
const mutate = (page, id, operation, changes = {}) => page.evaluate(async ({ id, operation, changes }) => {
  const reply = await fetch("/instant_record/mutations?scope=ada", {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ mutations: [{ id: crypto.randomUUID(), record_type: "Clip", record_id: id, operation, changes }] }),
  })
  return (await reply.json()).results[0].status
}, { id, operation, changes })
const record = (page, id, bytes) => mutate(page, id, "create", { title: id, byte_size: bytes, content_type: "application/octet-stream" })

// Look until the server is known to hold the file. (A promise handed to
// waitForFunction counts as true before it settles.)
const uploaded = async (page, id, timeout = 30000) => {
  for (const started = Date.now(); Date.now() - started < timeout;) {
    if ((await stat(page, id))?.uploaded) return
    await page.waitForTimeout(100)
  }
  assert.fail(`${id} was not sent within ${timeout} ms`)
}

const puts = (net) => net.asked.filter((entry) => entry.method === "PUT").map((entry) => Number(entry.offset))
const ranges = (net) => net.asked.filter((entry) => entry.method === "GET" && entry.range).map((entry) => entry.range)

try {
  await up()
  browser = await chromium.launch()
  const a = await device()
  const digests = {}

  await step("a file is kept with the sync server out of reach", async () => {
    a.net.down = true
    digests.one = await make(a.page, "one", 10 * MB)
    const about = await attach(a.page, "one")
    assert.deepEqual(about, { filename: "one.bin", content_type: "application/octet-stream", byte_size: 10 * MB })
    assert.deepEqual(await sync(a.page), { sent: 0, waiting: 1 })
    assert.equal(await digestOf(a.page, "one"), digests.one)
  })

  await step("it is still there after a reload, and still waiting", async () => {
    await a.page.reload()
    await a.page.waitForFunction(() => window.ready)
    assert.equal(await digestOf(a.page, "one"), digests.one)
    assert.deepEqual(await stat(a.page, "one").then(({ local, uploaded, size }) => ({ local, uploaded, size })),
      { local: true, uploaded: false, size: 10 * MB })
    assert.equal(existsSync(kept("one")), false)
  })

  await step("a file whose record has not reached the server waits for it", async () => {
    a.net.down = false
    assert.deepEqual(await sync(a.page), { sent: 0, waiting: 1 })
    assert.deepEqual(puts(a.net), [], "nothing is sent for a record the server does not have")
  })

  await step("once the record is there the file goes up in pieces, byte for byte", async () => {
    assert.equal(await record(a.page, "one", 10 * MB), "applied")
    assert.deepEqual(await sync(a.page), { sent: 1, waiting: 0 })
    assert.deepEqual(puts(a.net), offsets(10 * MB))
    assert.equal(sha(readFileSync(kept("one"))), digests.one)
    assert.equal((await stat(a.page, "one")).uploaded, true)
  })

  await step("an upload cut off after two pieces goes on from the third after a reload", async () => {
    digests.two = await make(a.page, "two", 20 * MB)
    assert.equal(await record(a.page, "two", 20 * MB), "applied")
    a.net.asked.length = 0
    a.net.cut = { method: "PUT", after: 2 }
    await attach(a.page, "two")
    // attach started a pass of its own: this waits for it, and looks again.
    assert.deepEqual(await sync(a.page), { sent: 0, waiting: 1 })
    assert.equal(existsSync(kept("two")), false)

    await a.page.reload()
    await a.page.waitForFunction(() => window.ready)
    a.net.cut = null
    a.net.asked.length = 0
    assert.deepEqual(await sync(a.page), { sent: 1, waiting: 0 })
    assert.deepEqual(puts(a.net), offsets(20 * MB, 2 * PIECE))
    assert.equal(sha(readFileSync(kept("two"))), digests.two)
  })

  const b = await device()
  await step("another device fetches the file a piece at a time, and keeps it", async () => {
    assert.equal(await stat(b.page, "two"), null)
    assert.equal(await digestOf(b.page, "two", "open"), digests.two)
    assert.equal(ranges(b.net).length, (20 * MB) / PIECE)
    assert.equal(ranges(b.net)[0], `bytes=0-${PIECE - 1}`)
  })

  await step("with no connection at all it is read from that device", async () => {
    await b.context.setOffline(true)
    b.net.asked.length = 0
    assert.equal(await digestOf(b.page, "two", "open"), digests.two)
    assert.equal(b.net.asked.length, 0)
    assert.equal(await failure(b.page, "one"), "TypeError", "a file that is not here cannot be had offline")
    await b.context.setOffline(false)
  })

  const c = await device()
  await step("a fetch cut off after two pieces keeps them and asks only for the rest", async () => {
    c.net.cut = { method: "GET", after: 2 }
    assert.equal(await failure(c.page, "two"), "TypeError")
    assert.deepEqual(await stat(c.page, "two").then(({ local, uploaded }) => ({ local, uploaded })), { local: false, uploaded: true })
    assert.equal(await digestOf(c.page, "two"), null, "half a file is no file")

    c.net.cut = null
    c.net.asked.length = 0
    await c.page.reload()
    await c.page.waitForFunction(() => window.ready)
    assert.equal(await digestOf(c.page, "two", "open"), digests.two)
    assert.deepEqual(ranges(c.net), byteRanges(20 * MB, 2 * PIECE))
  })

  await step("an audio element and a decoder take a file kept in pieces", async () => {
    const heard = await a.page.evaluate(async () => {
      // Two seconds of a 440 Hz tone as a 16-bit mono WAV, kept 32 KB to a piece.
      const rate = 44100
      const samples = rate * 2
      const wav = new DataView(new ArrayBuffer(44 + samples * 2))
      const say = (at, word) => [...word].forEach((letter, index) => wav.setUint8(at + index, letter.charCodeAt(0)))
      say(0, "RIFF"); wav.setUint32(4, 36 + samples * 2, true); say(8, "WAVEfmt "); wav.setUint32(16, 16, true)
      wav.setUint16(20, 1, true); wav.setUint16(22, 1, true); wav.setUint32(24, rate, true); wav.setUint32(28, rate * 2, true)
      wav.setUint16(32, 2, true); wav.setUint16(34, 16, true); say(36, "data"); wav.setUint32(40, samples * 2, true)
      for (let at = 0; at < samples; at++) wav.setInt16(44 + at * 2, Math.sin((at / rate) * 440 * 2 * Math.PI) * 12000, true)

      const small = new window.FileStore({ name: "tones", pieceSize: 32768 })
      await small.attach("Clip", "tone", new File([wav], "tone.wav", { type: "audio/wav" }))
      const audio = new Audio(await small.url("Clip", "tone"))
      await new Promise((resolve, reject) => {
        audio.onloadedmetadata = resolve
        audio.onerror = () => reject(new Error("the audio element refused the file"))
      })
      const decoded = await new OfflineAudioContext(1, rate, rate).decodeAudioData(await (await small.get("Clip", "tone")).arrayBuffer())
      return { element: audio.duration, decoded: decoded.duration, pieces: Math.ceil(wav.byteLength / 32768) }
    })
    assert.ok(heard.pieces > 1)
    assert.ok(Math.abs(heard.element - 2) < 0.01, `the element heard ${heard.element} s`)
    assert.ok(Math.abs(heard.decoded - 2) < 0.01, `the decoder heard ${heard.decoded} s`)
  })

  await step("another account is told the file is missing, and keeps nothing", async () => {
    const d = await device("scope=ben")
    assert.equal(await failure(d.page, "two"), "FileMissing")
    assert.equal(await stat(d.page, "two"), null)
    assert.equal(await d.page.evaluate(() => fetch("/instant_record/files/Clip/two?scope=ben").then((reply) => reply.status)), 404)
    await d.context.close()
  })

  await step("past its budget a device drops a file the server holds, and fetches it again when asked", async () => {
    // This device holds "two" (20 MB). With 25 MB to its name, "one" (10 MB) does not fit beside it.
    await open(b.page, `scope=ada&budget=${25 * MB}`)
    assert.equal(await digestOf(b.page, "one", "open"), digests.one)
    assert.equal(await stat(b.page, "two"), null)
    assert.equal(await digestOf(b.page, "two", "open"), digests.two)
    assert.equal(await stat(b.page, "one"), null)
    assert.deepEqual((await b.page.evaluate(() => window.files.list())).map((file) => file.id), ["two"])
  })

  await step("near the browser's own limit it does the same, and never drops what the server lacks", async () => {
    // Chromium is given 40 MB for this origin. It goes on reporting a quota of 10 GB more
    // than is used, whatever the limit is, so the store cannot see this coming: the write
    // that fails is what tells it.
    const q = await device()
    assert.equal(await digestOf(q.page, "one", "open"), digests.one)
    assert.equal(await digestOf(q.page, "two", "open"), digests.two)
    const session = await q.context.newCDPSession(q.page)
    await session.send("Storage.overrideQuotaForOrigin", { origin: ORIGIN, quotaSize: 40 * MB })
    const estimate = await q.page.evaluate(() => navigator.storage.estimate())
    assert.ok(estimate.quota > 1024 * MB, "the browser does not report the limit it enforces")

    // It holds 30 MB. 15 MB more does not fit: the least recently used goes.
    await make(q.page, "three", 15 * MB)
    await attach(q.page, "three")
    assert.equal(await stat(q.page, "one"), null)
    assert.ok(await digestOf(q.page, "three"))

    // 20 MB more: "two" goes. Then nothing is left that the server holds.
    await make(q.page, "four", 20 * MB)
    await attach(q.page, "four")
    assert.equal(await stat(q.page, "two"), null)
    await make(q.page, "five", 10 * MB)
    assert.equal(await q.page.evaluate(() => window.files.attach("Clip", "five", window.made.five).then(() => null, (error) => error.name)),
      "QuotaExceededError")
    assert.equal(await stat(q.page, "five"), null)
    assert.deepEqual((await q.page.evaluate(() => window.files.list())).map((file) => `${file.id} ${file.local} ${file.uploaded}`).sort(),
      ["four true false", "three true false"])
    await q.context.close()
  })

  await step("two tabs send a file once between them, and both learn it is on the server", async () => {
    digests.three = await make(a.page, "three", 15 * MB)
    await attach(a.page, "three")
    const second = await a.context.newPage()
    await open(second)
    assert.equal(await record(a.page, "three", 15 * MB), "applied")
    a.net.asked.length = 0
    await Promise.all([sync(a.page), sync(second)])
    await uploaded(a.page, "three")
    await uploaded(second, "three")
    assert.deepEqual(puts(a.net).sort((x, y) => x - y), offsets(15 * MB))
    assert.equal(sha(readFileSync(kept("three"))), digests.three)
    await second.close()
  })

  await step("a store that was started sends a waiting file by itself once its record arrives", async () => {
    digests.four = await make(a.page, "four", 20 * MB)
    await attach(a.page, "four")
    await open(a.page, "scope=ada&auto=1")
    assert.equal((await stat(a.page, "four")).uploaded, false)
    assert.equal(await record(a.page, "four", 20 * MB), "applied")
    await uploaded(a.page, "four")
    assert.equal(sha(readFileSync(kept("four"))), digests.four)
  })

  await step("a destroyed record takes its file from the server", async () => {
    assert.equal(await mutate(a.page, "one", "destroy"), "applied")
    assert.equal(existsSync(kept("one")), false)
    const e = await device()
    assert.equal(await failure(e.page, "one"), "FileMissing")
    await e.context.close()
  })

  if (process.argv.includes("--big")) {
    await step("a 200 MB file: kept, sent, and fetched on another device", async () => {
      const timed = async (run) => { const started = Date.now(); await run(); return Date.now() - started }
      digests.big = await make(a.page, "big", 200 * MB)
      assert.equal(await record(a.page, "big", 200 * MB), "applied")
      const keep = await timed(() => attach(a.page, "big"))
      const send = await timed(async () => assert.equal((await sync(a.page)).waiting, 0))
      assert.equal(sha(readFileSync(kept("big"))), digests.big)
      const fresh = await device()
      const fetched = await timed(async () => assert.equal(await digestOf(fresh.page, "big", "open"), digests.big))
      console.log(`  kept in ${keep} ms, sent in ${send} ms, fetched and kept elsewhere in ${fetched} ms (all on one machine)`)
      await fresh.context.close()
    })
  }

  const usage = await a.page.evaluate(() => window.files.usage())
  assert.deepEqual(pageErrors, [], "no page raised an error")
  console.log(`\n${passed.length} steps passed. The first device holds ${usage.files} files, ${Math.round(usage.bytes / MB)} MB; ` +
    `the browser ${usage.persisted ? "agreed" : "did not agree"} to keep this origin's storage.`)
} finally {
  await browser?.close()
  server.kill()
  if (!process.env.KEEP_FILES_APP) rmSync(root, { recursive: true, force: true })
  else console.log("kept " + root)
}
