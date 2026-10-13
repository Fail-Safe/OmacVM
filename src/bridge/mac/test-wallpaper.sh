#!/bin/bash
# Exercise the real store writer on a fixture. No AppKit, real wallpaper store
# or WallpaperAgent: main.swift supplies the store URL and a Process stand-in.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
python3 - "$HERE/wallpaper.swift" "$T/wallpaper.swift" <<'PY'
import pathlib
import sys
source = pathlib.Path(sys.argv[1]).read_text()
marker = 'let imageProvider = "com.apple.wallpaper.choice.image"'
assert source.count(marker) == 1, "wallpaper store writer boundary changed"
writer = source[source.index(marker):]
assert writer.count('func setOnAllSpaces(') == 1
pathlib.Path(sys.argv[2]).write_text('import Foundation\n' + writer)
PY
swiftc -O -swift-version 5 -o "$T/wallpaper-test" "$T/wallpaper.swift" "$HERE/tests/wallpaper/main.swift"
"$T/wallpaper-test" "$T"
