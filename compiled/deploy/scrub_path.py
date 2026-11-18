"""Replace the build machine's path inside the wasm with a neutral one of the same length.

usage: scrub_path.py <wasm> <local-prefix>
The string sits in a data segment, so a same-length replacement moves nothing.
"""
import sys

path, prefix = sys.argv[1], sys.argv[2].encode()
data = open(path, "rb").read()
count = data.count(prefix)
neutral = (b"/build" + b"/_" * len(prefix))[: len(prefix)]
assert len(neutral) == len(prefix)
patched = data.replace(prefix, neutral)
assert len(patched) == len(data)
open(path, "wb").write(patched)
print(f"replaced {count} occurrence(s); occurrences left: {patched.count(prefix)}; size {len(patched)}")
