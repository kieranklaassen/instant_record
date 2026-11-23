import assert from "node:assert/strict";
import { test } from "node:test";
import { createPagedSyncOPFSClasses } from "./opfs-wasi-core.js";

// Minimal stand-in matching @bjorn3/browser_wasi_shim@0.4.2's SyncOPFSFile, OpenSyncOPFSFile, and wasi constants.
const wasi = {
  ERRNO_SUCCESS: 0,
  ERRNO_BADF: 8,
  ERRNO_INVAL: 28,
  ERRNO_PERM: 63,
  FILETYPE_REGULAR_FILE: 4,
  OFLAGS_TRUNC: 8,
  FDFLAGS_APPEND: 1,
  RIGHTS_FD_WRITE: 64n,
  WHENCE_SET: 0,
  WHENCE_CUR: 1,
  WHENCE_END: 2,
  Filestat: class Filestat {
    constructor(ino, filetype, size) {
      this.ino = ino;
      this.filetype = filetype;
      this.size = size;
    }
  },
};

let nextIno = 1n;
class MockSyncOPFSFile {
  constructor(handle, options) {
    this.ino = nextIno++;
    this.handle = handle;
    this.readonly = !!options?.readonly;
  }
  get size() { return BigInt(this.handle.getSize()); }
  stat() { return new wasi.Filestat(this.ino, wasi.FILETYPE_REGULAR_FILE, this.size); }
}

class MockOpenSyncOPFSFile {
  constructor(file) {
    this.file = file;
    this.position = 0n;
    // Deliberately mirrors browser_wasi_shim@0.4.2's bug where OpenSyncOPFSFile issues a distinct ino.
    this.ino = nextIno++;
  }
  fd_seek(offset, whence) {
    let next;
    if (whence === wasi.WHENCE_SET) next = BigInt(offset);
    else if (whence === wasi.WHENCE_CUR) next = this.position + BigInt(offset);
    else if (whence === wasi.WHENCE_END) next = BigInt(this.file.handle.getSize()) + BigInt(offset);
    else return { ret: wasi.ERRNO_INVAL, offset: 0n };
    if (next < 0n) return { ret: wasi.ERRNO_INVAL, offset: 0n };
    this.position = next;
    return { ret: wasi.ERRNO_SUCCESS, offset: this.position };
  }
  fd_write(data) {
    if (this.file.readonly) return { ret: wasi.ERRNO_BADF, nwritten: 0 };
    const n = this.file.handle.write(data, { at: Number(this.position) });
    this.position += BigInt(n);
    return { ret: wasi.ERRNO_SUCCESS, nwritten: n };
  }
  fd_filestat_set_size(size) {
    this.file.handle.truncate(Number(size));
    return wasi.ERRNO_SUCCESS;
  }
  fd_allocate(offset, len) {
    if (BigInt(this.file.handle.getSize()) < offset + len) {
      this.file.handle.truncate(Number(offset + len));
    }
    return wasi.ERRNO_SUCCESS;
  }
}

function createMemorySyncHandle(initial = new Uint8Array(0)) {
  let bytes = new Uint8Array(initial);
  let flushes = 0;
  let closed = false;
  const reads = [];
  const writes = [];
  return {
    get flushes() { return flushes; },
    get closed() { return closed; },
    reads,
    writes,
    getSize() { return bytes.byteLength; },
    read(buf, { at = 0 } = {}) {
      const target = new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
      reads.push({ at, length: target.byteLength });
      if (at >= bytes.byteLength) return 0;
      const slice = bytes.subarray(at, at + target.byteLength);
      target.set(slice);
      return slice.byteLength;
    },
    write(buf, { at = 0 } = {}) {
      const src = buf instanceof Uint8Array ? buf : new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
      writes.push({ at, length: src.byteLength });
      const end = at + src.byteLength;
      if (end > bytes.byteLength) {
        const grown = new Uint8Array(end);
        grown.set(bytes);
        bytes = grown;
      }
      bytes.set(src, at);
      return src.byteLength;
    },
    truncate(size) {
      if (size < bytes.byteLength) {
        bytes = bytes.slice(0, size);
      } else if (size > bytes.byteLength) {
        const grown = new Uint8Array(size);
        grown.set(bytes);
        bytes = grown;
      }
    },
    flush() { flushes++; },
    close() { closed = true; },
  };
}

const { PagedSyncOPFSFile } = createPagedSyncOPFSClasses({
  SyncOPFSFile: MockSyncOPFSFile,
  OpenSyncOPFSFile: MockOpenSyncOPFSFile,
  wasi,
});

test("fd_pwrite and fd_pread operate on 4 KB SQLite pages without moving sequential position", () => {
  const handle = createMemorySyncHandle();
  const file = new PagedSyncOPFSFile(handle);
  const { ret, fd_obj: fd } = file.path_open(0, wasi.RIGHTS_FD_WRITE, 0);
  assert.equal(ret, wasi.ERRNO_SUCCESS);

  // Advance sequential cursor to offset 100.
  assert.deepEqual(fd.fd_seek(100n, wasi.WHENCE_SET), { ret: 0, offset: 100n });
  assert.deepEqual(fd.fd_tell(), { ret: 0, offset: 100n });

  // Write two 4096-byte pages via fd_pwrite (page 0 at 0, page 3 at 12288).
  const page0 = new Uint8Array(4096).fill(0x11);
  const page3 = new Uint8Array(4096).fill(0x33);
  assert.deepEqual(fd.fd_pwrite(page0, 0n), { ret: 0, nwritten: 4096 });
  assert.deepEqual(fd.fd_pwrite(page3, 12288n), { ret: 0, nwritten: 4096 });
  assert.equal(file.byteLength(), 16384);

  // Sequential cursor must remain untouched by pwrite/pread.
  assert.deepEqual(fd.fd_tell(), { ret: 0, offset: 100n });

  const read3 = fd.fd_pread(4096, 12288n);
  assert.equal(read3.ret, 0);
  assert.equal(read3.data.byteLength, 4096);
  assert.equal(read3.data[0], 0x33);
  assert.equal(read3.data[4095], 0x33);
  assert.deepEqual(fd.fd_tell(), { ret: 0, offset: 100n });

  // Reading past EOF returns partial/empty data cleanly.
  const eof = fd.fd_pread(4096, 16384n);
  assert.equal(eof.ret, 0);
  assert.equal(eof.data.byteLength, 0);

  // Only the two 4 KB pages were written — never whole-file copies.
  assert.deepEqual(handle.writes, [
    { at: 0, length: 4096 },
    { at: 12288, length: 4096 },
  ]);
});

test("fd_filestat_get matches path_filestat_get inode and reflects current size", () => {
  const handle = createMemorySyncHandle(new Uint8Array(8192));
  const file = new PagedSyncOPFSFile(handle);
  const { fd_obj: fd } = file.path_open(0, wasi.RIGHTS_FD_WRITE, 0);

  const pathStat = file.stat();
  const { ret, filestat: fdStat } = fd.fd_filestat_get();
  assert.equal(ret, 0);
  assert.equal(fdStat.ino, pathStat.ino);
  assert.equal(fdStat.size, 8192n);

  assert.equal(fd.fd_filestat_set_size(4096n), 0);
  assert.equal(fd.fd_filestat_get().filestat.size, 4096n);
});

test("fd_sync flushes handle and fd_close keeps underlying sync handle open for reuse", () => {
  const handle = createMemorySyncHandle();
  const file = new PagedSyncOPFSFile(handle);
  const { fd_obj: fd } = file.path_open(0, wasi.RIGHTS_FD_WRITE, 0);

  assert.equal(fd.fd_sync(), 0);
  assert.equal(handle.flushes, 1);
  assert.equal(fd.fd_close(), 0);
  assert.equal(handle.closed, false);

  file.close();
  assert.equal(handle.closed, true);
});

test("readonly files reject writes and truncations, and negative offsets return ERRNO_INVAL", () => {
  const handle = createMemorySyncHandle(new Uint8Array([1, 2, 3, 4]));
  const ro = new PagedSyncOPFSFile(handle, { readonly: true });

  assert.equal(ro.path_open(0, wasi.RIGHTS_FD_WRITE, 0).ret, wasi.ERRNO_PERM);
  assert.equal(ro.path_open(wasi.OFLAGS_TRUNC, 0n, 0).ret, wasi.ERRNO_PERM);

  const { ret, fd_obj: fd } = ro.path_open(0, 0n, 0);
  assert.equal(ret, 0);
  assert.equal(fd.fd_pwrite(new Uint8Array([9]), 0n).ret, wasi.ERRNO_BADF);
  assert.equal(fd.fd_pread(4, -1n).ret, wasi.ERRNO_INVAL);
  assert.equal(fd.fd_read(2).data.byteLength, 2);
  assert.equal(fd.fd_tell().offset, 2n);
});

test("writeAll, readAll, and truncate manage whole-file staging for migration and shell loads", () => {
  const handle = createMemorySyncHandle();
  const file = new PagedSyncOPFSFile(handle);
  const payload = new TextEncoder().encode("SQLite format 3\0");

  file.writeAll(payload);
  assert.equal(file.byteLength(), payload.byteLength);
  assert.deepEqual(file.readAll(), payload);
  assert.equal(handle.flushes, 1);

  file.truncate(0);
  assert.equal(file.byteLength(), 0);
  assert.deepEqual(file.readAll(), new Uint8Array(0));
  assert.equal(handle.flushes, 2);
});
