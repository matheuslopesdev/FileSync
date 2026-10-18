# File Sync

Menu bar app that mirrors folders (source → target, including deletions) using FSEvents + `rsync`.

- First run of a sync copies everything; afterwards only changed folders are synced. Changes made while the app is closed are replayed on next launch.
- Syncs are stored in iCloud Drive: `~/Library/Mobile Documents/com~apple~CloudDocs/File Sync/syncs.json`.
- Build: `./build.sh` → `File Sync.app`. Install to `/Applications`: `./install.sh`. Self-check: `./test.sh`.
