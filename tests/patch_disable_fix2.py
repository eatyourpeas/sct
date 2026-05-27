"""Patch Fix 2: revert .quoting(false) → .quoting(true) to reproduce the bug."""
import sys

src = open('src/rf2.rs').read()
patched = src.replace('.quoting(false)', '.quoting(true)', 1)
if patched == src:
    sys.exit("ERROR: .quoting(false) not found in src/rf2.rs")
open('src/rf2.rs', 'w').write(patched)
print("[patched] .quoting(false) -> .quoting(true)  (Fix 2 disabled)")
