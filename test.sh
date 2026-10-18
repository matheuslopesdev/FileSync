#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
OUT=$(mktemp -d)
swiftc -swift-version 5 Sources/FileSync/Watcher.swift Sources/FileSync/Store.swift Sources/FileSync/TwoWay.swift Tests/main.swift -o "$OUT/selftest"
"$OUT/selftest"
rm -rf "$OUT"
