# File Sync

A tiny macOS menu bar app that keeps folders in sync. Pick a source and a target; whenever something changes in the source, File Sync copies it to the target with `rsync`, deletions included. Turn on **two-way** and changes flow both ways.

No accounts, no background daemons, no dependencies. Just FSEvents, `rsync` and SwiftUI.

> [!WARNING]
> In a one-way sync the target becomes an exact mirror of the source. Files in the target that are not in the source **are deleted**. Point it at an empty folder or one you don't mind losing.

## Features

- **One-way mirror** of any number of source → target folder pairs.
- **Two-way sync** as an option per pair, with conflict copies instead of lost edits.
- **Incremental**: the first run copies everything; after that only changed folders are synced.
- **Catches up after downtime**: changes made while the app was closed are replayed on next launch (FSEvents history).
- **Ignore rules** in `.gitignore` style, shared by every sync.
- **Safety check**: refuses pairs where the source and target are the same folder or one is inside the other.
- **Settings in iCloud Drive**, so your sync list and ignore rules follow you across Macs.
- **Launch at Login** toggle in the menu.
- Live file/folder counts and last sync time per pair.

## Requirements

- macOS 15 (Sequoia) or later
- Xcode 16 / Swift 6 toolchain (to build)

## Install

```sh
git clone <this repo>
cd "File Sync"
./build.sh      # builds "File Sync.app" in the repo root
./install.sh    # copies it to /Applications and launches it
```

A prebuilt, ad-hoc signed `File Sync.app` is also in the repo. If you download it instead of cloning, macOS Gatekeeper will block it the first time: open it, then go to **System Settings → Privacy & Security** and click **Open Anyway**.

## Usage

1. Click the **⇆** icon in the menu bar and choose **Open File Sync…**
2. Click **+**, choose a source and a target folder, optionally turn on **Two-way sync**, and click **Add**. The first full copy starts right away.
3. Leave it running. Use **Sync All Now** from the menu, or the ↻ button on a row, to force a full sync.

Removing a sync only stops watching; files already in the target are kept. To switch a sync between one-way and two-way, remove it and add it again.

### Two-way syncs

- New files, edits and deletions on either side are copied to the other side.
- The first pass only merges: it copies what is missing on each side and deletes nothing.
- **Conflicts**: if the same file changed on both sides, the newer one wins and the other is kept next to it as `name (conflict).ext` on both sides.
- An edit beats a delete: if one side deleted a file the other side changed, the changed file comes back.
- **Safety guard**: if one side is suddenly empty (an unplugged drive, a wiped folder), File Sync stops instead of deleting everything on the other side.
- Each change rescans both folders in full, so very large folders sync more slowly than in one-way mode.

### Ignore rules

The **Ignore** tab takes one pattern per line, like `.gitignore`:

```gitignore
# comments start with #
.DS_Store
*.log

# trailing / matches folders only
node_modules/

# leading / anchors to the source root
/build

# ! re-includes a file
!keep.log
```

Rules apply to every sync. Saving re-runs all syncs with the new rules. Files that are ignored but already in a target are left there.

## Where data lives

| What | Where |
| --- | --- |
| Sync list | `~/Library/Mobile Documents/com~apple~CloudDocs/File Sync/syncs.json` |
| Ignore rules | `~/Library/Mobile Documents/com~apple~CloudDocs/File Sync/ignore.txt` |
| Last FSEvents position and counts | app `UserDefaults` (per Mac) |
| Two-way snapshot (last synced state) | `~/Library/Application Support/File Sync/<sync id>.json` (per Mac) |

## How it works

- Each sync has a `Watcher` that listens to FSEvents on the source folder.
- Changed paths are reduced to the smallest set of existing folders that covers them, and `rsync -a --delete` runs scoped to those folders.
- After each successful run the last FSEvents ID is saved, so a restart picks up exactly where it left off. If FSEvents reports a history gap, the next run is a full sync.
- Two-way syncs watch both folders. Each pass lists both sides with `rsync --list-only` and compares them with a snapshot of the last pass. That is how it tells "deleted here" apart from "new there". Then it copies with `rsync --files-from` and deletes with `FileManager`.

## Development

```sh
./test.sh    # compiles and runs the self-check in Tests/main.swift
./build.sh   # release build + app bundle + icon
```

Source layout:

- `Sources/FileSync/FileSyncApp.swift`: menu bar UI and windows
- `Sources/FileSync/Store.swift`: sync list, persistence, ignore rules
- `Sources/FileSync/Watcher.swift`: FSEvents watcher and `rsync` runner
- `Sources/FileSync/TwoWay.swift`: two-way planning (what to copy, delete, or mark as a conflict)
- `Support/`: `Info.plist` and the icon generator used by `build.sh`
