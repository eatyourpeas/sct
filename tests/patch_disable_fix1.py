"""Patch Fix 1: replace parse_active_token body with strict raw == "1" to reproduce the bug."""
import re, sys

src = open('src/rf2.rs').read()
replacement = (
    'fn parse_active_token(token: Option<&str>) -> bool {\n'
    '    let raw = token.unwrap_or_default();\n'
    '    raw == "1"  // original strict check -- NUL/BOM padding breaks this\n'
    '}'
)
patched, n = re.subn(
    r'fn parse_active_token\(token: Option<&str>\) -> bool \{.*?\}',
    replacement,
    src,
    flags=re.DOTALL,
)
if n == 0:
    sys.exit("ERROR: parse_active_token not found in src/rf2.rs")
open('src/rf2.rs', 'w').write(patched)
print('[patched] parse_active_token -> strict raw == "1"  (Fix 1 disabled)')
