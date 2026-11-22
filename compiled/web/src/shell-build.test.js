import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const web = join(dirname(fileURLToPath(import.meta.url)), "..");
const vite = join(web, "node_modules/vite/bin/vite.js");

// Firefox takes an import map only before the first module load in a page. The shell writes
// the app's own page, import map and all, into its document, so the shell may load no module.
test("the built shell loads no module in the page", { skip: !existsSync(vite) && "vite is not installed in compiled/web" }, () => {
  const out = mkdtempSync(join(tmpdir(), "instant-record-shell-"));
  try {
    execFileSync(process.execPath, [vite, "build", "--outDir", out, "--emptyOutDir", "--logLevel", "error"], {
      cwd: web,
      env: { ...process.env, VITE_MANIFEST: "{}", VITE_WASM_URL: "/app.wasm", VITE_SOURCE_VERSION: "test" },
    });
    const html = readFileSync(join(out, "index.html"), "utf8");
    assert.doesNotMatch(html, /type="module"/);
    assert.doesNotMatch(html, /modulepreload/);

    const [, entry] = html.match(/<script defer src="\/(harness\/[^"]+)"><\/script>/) || [];
    assert.ok(entry, "the shell's script is a deferred classic script");
    // Compiling as a classic script throws on import, export, import.meta and top-level await.
    const source = readFileSync(join(out, entry), "utf8");
    new vm.Script(source);
    assert.match(source, /^"use strict";/, "the shell's script stays strict, as the module it is written as");
    assert.ok(readdirSync(join(out, "harness")).some(name => name.startsWith("worker-")), "the worker is its own file");
  } finally {
    rmSync(out, { recursive: true, force: true });
  }
});
