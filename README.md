# File Sync

Menu bar app that mirrors folders (source → target, including deletions) using FSEvents + `rsync`.

- First run of a sync copies everything; afterwards only changed folders are synced. Changes made while the app is closed are replayed on next launch.
- Syncs are stored in `syncs.json` and auto-committed to this repo (pushed when a remote exists).
- Build: `./build.sh` → `File Sync.app`. Self-check: `./test.sh`.
