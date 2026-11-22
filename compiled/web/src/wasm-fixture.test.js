// Minimal WebAssembly 1.0 binary assembler for real WASI reactor tests (zero external toolchain).
function uleb(n) {
  const out = [];
  let v = n >>> 0;
  do {
    let b = v & 0x7f;
    v >>>= 7;
    if (v !== 0) b |= 0x80;
    out.push(b);
  } while (v !== 0);
  return out;
}

function sleb(n) {
  const out = [];
  let v = n | 0;
  let more = true;
  while (more) {
    let b = v & 0x7f;
    v >>= 7;
    if ((v === 0 && (b & 0x40) === 0) || (v === -1 && (b & 0x40) !== 0)) more = false;
    else b |= 0x80;
    out.push(b);
  }
  return out;
}

function str(s) {
  const bytes = [...new TextEncoder().encode(s)];
  return [...uleb(bytes.length), ...bytes];
}

function section(id, payload) {
  return [id, ...uleb(payload.length), ...payload];
}

export function buildTestWasmBytes({
  bootTraps = false,
  syncExit = 0,
  syncTraps = false,
  syncStderr = "",
  syncOut = "changed pending=0 cursor=7",
  syncEvents = "",
  syncRequest = "",
  streamExit = 0,
  streamTraps = false,
  streamStderr = "",
  streamOut = "applied=1 cursor=8 bootstrap=ready",
  cursorExit = 0,
  cursorOut = "cursor=7 pending=0 bootstrap=ready identity=",
  planExit = 0,
  planOut = '{"push":"","bootstrap":false}',
  reqExit = 0,
  reqOut = "200\nContent-Type: text/plain\n\nok",
  histExit = 0,
  histOut = '{"ok":true,"applied":0,"has_more":false}',
} = {}) {
  const enc = new TextEncoder();
  const dataChunks = [];
  let cursor = 1024;
  function alloc(text) {
    const bytes = enc.encode(text);
    const ptr = cursor;
    dataChunks.push({ offset: ptr, bytes });
    cursor += bytes.length + 1;
    return { ptr, len: bytes.length };
  }

  const paths = {
    out: alloc("host/out"),
    events: alloc("host/events"),
    request: alloc("host/request"),
    response: alloc("host/response"),
  };
  const payloads = {
    syncStderr: alloc(syncStderr),
    syncOut: alloc(syncOut),
    syncEvents: alloc(syncEvents),
    syncRequest: alloc(syncRequest),
    streamStderr: alloc(streamStderr),
    streamOut: alloc(streamOut),
    cursorOut: alloc(cursorOut),
    planOut: alloc(planOut),
    reqOut: alloc(reqOut),
    histOut: alloc(histOut),
  };

  const IOV = 0;
  const NWRITTEN = 16;
  const OPENED_FD = 24;
  const READ_BUF = 64;

  const types = [
    [0x60, 0, 0],
    [0x60, 0, 1, 0x7f],
    [0x60, 4, 0x7f, 0x7f, 0x7f, 0x7f, 1, 0x7f],
    [0x60, 9, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7e, 0x7e, 0x7f, 0x7f, 1, 0x7f],
    [0x60, 1, 0x7f, 1, 0x7f],
  ];

  const imports = [
    [...str("wasi_snapshot_preview1"), ...str("fd_write"), 0x00, 0x02],
    [...str("wasi_snapshot_preview1"), ...str("fd_read"), 0x00, 0x02],
    [...str("wasi_snapshot_preview1"), ...str("path_open"), 0x00, 0x03],
    [...str("wasi_snapshot_preview1"), ...str("fd_close"), 0x00, 0x04],
  ];

  const i32Const = (v) => [0x41, ...sleb(v)];
  const i64Const = (v) => [0x42, ...sleb(v)];
  const store32 = (addr, val) => [...i32Const(addr), ...i32Const(val), 0x36, 0x02, 0x00];
  const load32 = (addr) => [...i32Const(addr), 0x28, 0x02, 0x00];

  function writeFdCode(fdExpr, data) {
    if (!data.len) return [];
    return [
      ...store32(IOV, data.ptr),
      ...store32(IOV + 4, data.len),
      ...fdExpr,
      ...i32Const(IOV),
      ...i32Const(1),
      ...i32Const(NWRITTEN),
      0x10, 0x00,
      0x1a,
    ];
  }

  function writeFileCode(pathData, contentData) {
    if (!contentData.len) return [];
    return [
      ...i32Const(3),
      ...i32Const(0),
      ...i32Const(pathData.ptr),
      ...i32Const(pathData.len),
      ...i32Const(9),
      ...i64Const(0),
      ...i64Const(0),
      ...i32Const(0),
      ...i32Const(OPENED_FD),
      0x10, 0x02,
      0x1a,
      ...writeFdCode(load32(OPENED_FD), contentData),
      ...load32(OPENED_FD),
      0x10, 0x03,
      0x1a,
    ];
  }

  function openAndReadFileCode(pathData) {
    return [
      ...i32Const(3),
      ...i32Const(0),
      ...i32Const(pathData.ptr),
      ...i32Const(pathData.len),
      ...i32Const(0),
      ...i64Const(0),
      ...i64Const(0),
      ...i32Const(0),
      ...i32Const(OPENED_FD),
      0x10, 0x02,
      0x1a,
      ...store32(IOV, READ_BUF),
      ...store32(IOV + 4, 256),
      ...load32(OPENED_FD),
      ...i32Const(IOV),
      ...i32Const(1),
      ...i32Const(NWRITTEN),
      0x10, 0x01,
      0x1a,
      ...load32(OPENED_FD),
      0x10, 0x03,
      0x1a,
    ];
  }

  function body(ops) {
    const raw = [0x00, ...ops, 0x0b];
    return [...uleb(raw.length), ...raw];
  }

  const bootBody = body(bootTraps ? [0x00] : []);
  const syncBody = body([
    ...writeFileCode(paths.events, payloads.syncEvents),
    ...(payloads.syncRequest.len ? [...writeFileCode(paths.request, payloads.syncRequest), ...openAndReadFileCode(paths.response)] : []),
    ...writeFdCode(i32Const(2), payloads.syncStderr),
    ...(syncTraps ? [0x00] : [...writeFileCode(paths.out, payloads.syncOut), ...i32Const(syncExit)]),
  ]);
  const streamBody = body([
    ...writeFdCode(i32Const(2), payloads.streamStderr),
    ...(streamTraps ? [0x00] : [...writeFileCode(paths.out, payloads.streamOut), ...i32Const(streamExit)]),
  ]);
  const cursorBody = body([...writeFileCode(paths.out, payloads.cursorOut), ...i32Const(cursorExit)]);
  const planBody = body([...writeFileCode(paths.out, payloads.planOut), ...i32Const(planExit)]);
  const reqBody = body([...writeFileCode(paths.out, payloads.reqOut), ...i32Const(reqExit)]);
  const histBody = body([...writeFileCode(paths.out, payloads.histOut), ...i32Const(histExit)]);

  const funcTypes = [0, 1, 1, 1, 1, 1, 1];
  const exportsList = [
    [...str("memory"), 0x02, 0x00],
    [...str("wasm_boot"), 0x00, 4],
    [...str("wasm_sync"), 0x00, 5],
    [...str("wasm_stream"), 0x00, 6],
    [...str("wasm_cursor"), 0x00, 7],
    [...str("wasm_sync_plan"), 0x00, 8],
    [...str("wasm_request"), 0x00, 9],
    [...str("wasm_history"), 0x00, 10],
  ];

  const dataSegments = dataChunks
    .filter((c) => c.bytes.length > 0)
    .map((c) => [0x00, ...i32Const(c.offset), 0x0b, ...uleb(c.bytes.length), ...c.bytes]);

  return new Uint8Array([
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    ...section(1, [...uleb(types.length), ...types.flat()]),
    ...section(2, [...uleb(imports.length), ...imports.flat()]),
    ...section(3, [...uleb(funcTypes.length), ...funcTypes]),
    ...section(5, [1, 0x00, 1]),
    ...section(7, [...uleb(exportsList.length), ...exportsList.flat()]),
    ...section(10, [...uleb(7), ...bootBody, ...syncBody, ...streamBody, ...cursorBody, ...planBody, ...reqBody, ...histBody]),
    ...section(11, [...uleb(dataSegments.length), ...dataSegments.flat()]),
  ]);
}

export function buildTestWasmModule(options = {}) {
  return new WebAssembly.Module(buildTestWasmBytes(options));
}
