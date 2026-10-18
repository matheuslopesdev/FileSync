#!/bin/zsh
# Installs "File Sync.app" from this repo into /Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")"

pkill -x FileSync || true
rm -rf "/Applications/File Sync.app"
ditto "File Sync.app" "/Applications/File Sync.app"
open "/Applications/File Sync.app"
echo "Installed /Applications/File Sync.app"
