// Core factory extending @bjorn3/browser_wasi_shim's SyncOPFSFile / OpenSyncOPFSFile
// with page-level WASI syscalls (fd_pread, fd_pwrite, fd_tell) and consistent inode
// stats required by SQLite's POSIX VFS without touching SQLite's C code.
//
// Kept dependency-free so unit tests run directly in Node without node_modules.
export function createPagedSyncOPFSClasses({ SyncOPFSFile, OpenSyncOPFSFile, wasi }) {
  class PagedOpenSyncOPFSFile extends OpenSyncOPFSFile {
    constructor(file) {
      super(file);
      // Match the parent inode so stat() (path_filestat_get) and fstat() (fd_filestat_get)
      // agree on st_ino for SQLite's inode identity checks.
      this.ino = file.ino;
    }

    fd_filestat_get() {
      return { ret: wasi.ERRNO_SUCCESS, filestat: this.file.stat() };
    }

    fd_read(size) {
      if (size <= 0) return { ret: wasi.ERRNO_SUCCESS, data: new Uint8Array(0) };
      const buf = new Uint8Array(size);
      const n = this.file.handle.read(buf, { at: Number(this.position) });
      this.position += BigInt(n);
      return { ret: wasi.ERRNO_SUCCESS, data: buf.subarray(0, n) };
    }

    fd_pread(size, offset) {
      const pos = BigInt(offset);
      if (pos < 0n) return { ret: wasi.ERRNO_INVAL, data: new Uint8Array(0) };
      if (size <= 0) return { ret: wasi.ERRNO_SUCCESS, data: new Uint8Array(0) };
      const buf = new Uint8Array(size);
      const n = this.file.handle.read(buf, { at: Number(pos) });
      return { ret: wasi.ERRNO_SUCCESS, data: buf.subarray(0, n) };
    }

    fd_pwrite(data, offset) {
      if (this.file.readonly) return { ret: wasi.ERRNO_BADF, nwritten: 0 };
      const pos = BigInt(offset);
      if (pos < 0n) return { ret: wasi.ERRNO_INVAL, nwritten: 0 };
      const n = this.file.handle.write(data, { at: Number(pos) });
      return { ret: wasi.ERRNO_SUCCESS, nwritten: n };
    }

    fd_tell() {
      return { ret: wasi.ERRNO_SUCCESS, offset: this.position };
    }

    fd_sync() {
      this.file.handle.flush();
      return wasi.ERRNO_SUCCESS;
    }

    fd_close() {
      // Keep the underlying SyncAccessHandle open while the Inode stays mounted.
      return wasi.ERRNO_SUCCESS;
    }
  }

  class PagedSyncOPFSFile extends SyncOPFSFile {
    path_open(oflags, fs_rights_base, fd_flags) {
      if (this.readonly && (BigInt(fs_rights_base) & BigInt(wasi.RIGHTS_FD_WRITE)) === BigInt(wasi.RIGHTS_FD_WRITE)) {
        return { ret: wasi.ERRNO_PERM, fd_obj: null };
      }
      if ((oflags & wasi.OFLAGS_TRUNC) === wasi.OFLAGS_TRUNC) {
        if (this.readonly) return { ret: wasi.ERRNO_PERM, fd_obj: null };
        this.handle.truncate(0);
      }
      const file = new PagedOpenSyncOPFSFile(this);
      if (fd_flags & wasi.FDFLAGS_APPEND) file.fd_seek(0n, wasi.WHENCE_END);
      return { ret: wasi.ERRNO_SUCCESS, fd_obj: file };
    }

    byteLength() {
      return this.handle.getSize();
    }

    readAll() {
      const size = this.handle.getSize();
      if (size === 0) return new Uint8Array(0);
      const buf = new Uint8Array(size);
      const n = this.handle.read(buf, { at: 0 });
      return n === size ? buf : buf.subarray(0, n);
    }

    writeAll(bytes) {
      if (this.readonly) throw new Error("Cannot write to a readonly SyncOPFSFile");
      const data = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
      this.handle.truncate(0);
      if (data.byteLength > 0) this.handle.write(data, { at: 0 });
      this.handle.flush();
    }

    truncate(size = 0) {
      if (this.readonly) throw new Error("Cannot truncate a readonly SyncOPFSFile");
      this.handle.truncate(size);
      this.handle.flush();
    }

    flush() {
      this.handle.flush();
    }

    close() {
      this.handle.close();
    }
  }

  return { PagedSyncOPFSFile, PagedOpenSyncOPFSFile };
}
