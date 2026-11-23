// Minimal pure-JS WASI preview1 implementation mirroring the subset of
// @bjorn3/browser_wasi_shim used by AppHost. Used as a Node fallback when
// compiled/web/node_modules is not installed (e.g. unit tests or standalone
// replay of minimal test WASM modules). Full compiled Rails apps should still
// use @bjorn3/browser_wasi_shim via WEB_NODE_MODULES.

const encoder = new TextEncoder();
const decoder = new TextDecoder();

const ESUCCESS = 0;
const EBADF = 8;
const EINVAL = 28;
const ENOENT = 44;
const ENOTDIR = 54;

export class File {
  constructor(data = new Uint8Array()) {
    this.data = data instanceof Uint8Array ? data : new Uint8Array(data);
  }

  path_open(oflags = 0) {
    if (oflags & 8) this.data = new Uint8Array(); // OFLAGS_TRUNC
    return { ret: ESUCCESS, fd_obj: new OpenFile(this) };
  }
}

export class OpenFile {
  constructor(file) {
    this.file = file;
    this.file_pos = 0;
  }

  fd_read(iovs, view) {
    let total = 0;
    for (const { buf, buf_len } of iovs) {
      const avail = Math.max(0, this.file.data.length - this.file_pos);
      const n = Math.min(buf_len, avail);
      if (n > 0) {
        new Uint8Array(view.buffer, buf, n).set(this.file.data.subarray(this.file_pos, this.file_pos + n));
        this.file_pos += n;
        total += n;
      }
      if (n < buf_len) break;
    }
    return { ret: ESUCCESS, nread: total };
  }

  fd_write(iovs, view) {
    let total = 0;
    const chunks = [];
    for (const { buf, buf_len } of iovs) {
      chunks.push(new Uint8Array(view.buffer, buf, buf_len).slice());
      total += buf_len;
    }
    const end = this.file_pos + total;
    const next = new Uint8Array(Math.max(this.file.data.length, end));
    next.set(this.file.data);
    let cursor = this.file_pos;
    for (const chunk of chunks) {
      next.set(chunk, cursor);
      cursor += chunk.length;
    }
    this.file.data = next;
    this.file_pos = cursor;
    return { ret: ESUCCESS, nwritten: total };
  }
}

export class ConsoleStdout {
  constructor(writeFn) {
    this.writeFn = writeFn;
  }

  static lineBuffered(onLine) {
    let buffer = "";
    return new ConsoleStdout((bytes) => {
      buffer += decoder.decode(bytes, { stream: true });
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";
      for (const line of lines) onLine(line);
    });
  }

  fd_write(iovs, view) {
    let total = 0;
    for (const { buf, buf_len } of iovs) {
      this.writeFn(new Uint8Array(view.buffer, buf, buf_len).slice());
      total += buf_len;
    }
    return { ret: ESUCCESS, nwritten: total };
  }
}

export class Directory {
  constructor(contents = new Map()) {
    this.contents = contents instanceof Map ? contents : new Map(Object.entries(contents));
  }
}

export class PreopenDirectory {
  constructor(prestat_name, contents) {
    this.prestat_name = prestat_name;
    this.dir = contents instanceof Directory ? contents : new Directory(contents);
  }
}

export class WASI {
  constructor(args = [], env = [], fds = []) {
    this.args = args.map((a) => encoder.encode(String(a) + "\0"));
    this.env = env.map((e) => encoder.encode(String(e) + "\0"));
    this.fds = fds.slice();
    this.inst = null;
    this.wasiImport = this.buildImports();
  }

  initialize(instance) {
    this.inst = instance;
    if (typeof instance.exports._initialize === "function") {
      instance.exports._initialize();
    }
  }

  memoryView() {
    return new DataView(this.inst.exports.memory.buffer);
  }

  readIovs(iovsPtr, iovsLen) {
    const view = this.memoryView();
    const out = [];
    for (let i = 0; i < iovsLen; i++) {
      const base = iovsPtr + i * 8;
      out.push({ buf: view.getUint32(base, true), buf_len: view.getUint32(base + 4, true) });
    }
    return out;
  }

  resolvePath(dirFd, relPath) {
    const entry = this.fds[dirFd];
    if (!entry || !entry.dir) return { err: EBADF };
    const parts = relPath.split("/").filter((p) => p && p !== ".");
    if (parts.length === 0) return { parent: null, name: "", target: entry.dir };
    let current = entry.dir;
    for (let i = 0; i < parts.length - 1; i++) {
      const next = current.contents.get(parts[i]);
      if (!(next instanceof Directory)) return { err: next ? ENOTDIR : ENOENT };
      current = next;
    }
    const name = parts[parts.length - 1];
    return { parent: current, name, target: current.contents.get(name) };
  }

  buildImports() {
    return {
      args_sizes_get: (argcPtr, argvBufSizePtr) => {
        const view = this.memoryView();
        view.setUint32(argcPtr, this.args.length, true);
        view.setUint32(argvBufSizePtr, this.args.reduce((s, a) => s + a.length, 0), true);
        return ESUCCESS;
      },
      args_get: (argvPtr, argvBufPtr) => {
        const view = this.memoryView();
        const mem = new Uint8Array(view.buffer);
        let buf = argvBufPtr;
        for (let i = 0; i < this.args.length; i++) {
          view.setUint32(argvPtr + i * 4, buf, true);
          mem.set(this.args[i], buf);
          buf += this.args[i].length;
        }
        return ESUCCESS;
      },
      environ_sizes_get: (countPtr, bufSizePtr) => {
        const view = this.memoryView();
        view.setUint32(countPtr, this.env.length, true);
        view.setUint32(bufSizePtr, this.env.reduce((s, e) => s + e.length, 0), true);
        return ESUCCESS;
      },
      environ_get: (envPtr, envBufPtr) => {
        const view = this.memoryView();
        const mem = new Uint8Array(view.buffer);
        let buf = envBufPtr;
        for (let i = 0; i < this.env.length; i++) {
          view.setUint32(envPtr + i * 4, buf, true);
          mem.set(this.env[i], buf);
          buf += this.env[i].length;
        }
        return ESUCCESS;
      },
      fd_prestat_get: (fd, bufPtr) => {
        const entry = this.fds[fd];
        if (!(entry instanceof PreopenDirectory)) return EBADF;
        const view = this.memoryView();
        const nameBytes = encoder.encode(entry.prestat_name);
        view.setUint8(bufPtr, 0); // PREOPENTYPE_DIR
        view.setUint32(bufPtr + 4, nameBytes.length, true);
        return ESUCCESS;
      },
      fd_prestat_dir_name: (fd, pathPtr, pathLen) => {
        const entry = this.fds[fd];
        if (!(entry instanceof PreopenDirectory)) return EBADF;
        const nameBytes = encoder.encode(entry.prestat_name);
        new Uint8Array(this.memoryView().buffer, pathPtr, Math.min(pathLen, nameBytes.length)).set(
          nameBytes.subarray(0, pathLen),
        );
        return ESUCCESS;
      },
      path_open: (dirFd, _dirflags, pathPtr, pathLen, oflags, rightsBase, _rightsInheriting, fdFlags, openedFdPtr) => {
        const view = this.memoryView();
        const relPath = decoder.decode(new Uint8Array(view.buffer, pathPtr, pathLen));
        const resolved = this.resolvePath(dirFd, relPath);
        if (resolved.err) return resolved.err;
        let file = resolved.target;
        if (!file && (oflags & 1)) {
          file = new File(new Uint8Array());
          resolved.parent.contents.set(resolved.name, file);
        }
        if (!file || typeof file.path_open !== "function") return ENOENT;
        const { ret, fd_obj } = file.path_open(oflags, rightsBase, fdFlags);
        if (ret !== ESUCCESS) return ret;
        let slot = this.fds.indexOf(null);
        if (slot < 0) {
          slot = this.fds.length;
          this.fds.push(fd_obj);
        } else {
          this.fds[slot] = fd_obj;
        }
        view.setUint32(openedFdPtr, slot, true);
        return ESUCCESS;
      },
      fd_read: (fd, iovsPtr, iovsLen, nreadPtr) => {
        const entry = this.fds[fd];
        if (!entry || typeof entry.fd_read !== "function") return EBADF;
        const view = this.memoryView();
        const { ret, nread } = entry.fd_read(this.readIovs(iovsPtr, iovsLen), view);
        view.setUint32(nreadPtr, nread, true);
        return ret;
      },
      fd_write: (fd, iovsPtr, iovsLen, nwrittenPtr) => {
        const entry = this.fds[fd];
        if (!entry || typeof entry.fd_write !== "function") return EBADF;
        const view = this.memoryView();
        const { ret, nwritten } = entry.fd_write(this.readIovs(iovsPtr, iovsLen), view);
        view.setUint32(nwrittenPtr, nwritten, true);
        return ret;
      },
      fd_close: (fd) => {
        if (fd < 0 || fd >= this.fds.length || !this.fds[fd]) return EBADF;
        this.fds[fd] = null;
        return ESUCCESS;
      },
      fd_seek: (fd, offset, whence, newOffsetPtr) => {
        const entry = this.fds[fd];
        if (!entry || !entry.file) return EBADF;
        const delta = Number(offset);
        if (whence === 0) entry.file_pos = delta;
        else if (whence === 1) entry.file_pos += delta;
        else if (whence === 2) entry.file_pos = entry.file.data.length + delta;
        else return EINVAL;
        this.memoryView().setBigUint64(newOffsetPtr, BigInt(Math.max(0, entry.file_pos)), true);
        return ESUCCESS;
      },
      clock_time_get: (_id, _precision, timePtr) => {
        this.memoryView().setBigUint64(timePtr, BigInt(Date.now()) * 1000000n, true);
        return ESUCCESS;
      },
      random_get: (bufPtr, bufLen) => {
        const slice = new Uint8Array(this.memoryView().buffer, bufPtr, bufLen);
        if (globalThis.crypto?.getRandomValues) globalThis.crypto.getRandomValues(slice);
        return ESUCCESS;
      },
      proc_exit: (code) => {
        throw new Error(`WASI proc_exit(${code})`);
      },
    };
  }
}
