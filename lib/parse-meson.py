#!/usr/bin/env python3
"""Extract dependency version floors from a meson.build file.

Reads meson.build on stdin and prints one tab-separated line:
    <gtk4 floor>  <libadwaita floor>  <mpv floor>

A floor is "0" when the dependency is not pinned. Prints nothing on a parse
failure so callers can distinguish "no opinion" from "no requirement".
"""

from __future__ import annotations

import re
import sys

# dependency('gtk4', version: '>=4.16.0')
# dependency('libadwaita-1', version: '>= 1.8.0')
# may also wrap across lines, hence DOTALL and a bounded body.
_DEP = r"dependency\(\s*'%s'\s*(?:,\s*(?P<kw>(?:[^()']|'[^']*')*))?\)"
_VER = r"version\s*:\s*'\s*(?:>=|>|=)\s*(?P<ver>[0-9][0-9A-Za-z.~+:-]*)'"


def floor(src: str, name: str) -> str:
    pattern = re.compile(_DEP % re.escape(name), re.DOTALL)
    for match in pattern.finditer(src):
        kw = match.group("kw") or ""
        ver = re.search(_VER, kw)
        if ver:
            return ver.group("ver")
    return "0"


def main() -> int:
    src = sys.stdin.read()
    # src/meson.build is a subdir file and has no project() call, so a missing
    # project() is not an error. An empty read is.
    if not src.strip():
        return 1
    print("\t".join(floor(src, n) for n in ("gtk4", "libadwaita-1", "mpv")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
