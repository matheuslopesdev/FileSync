// Self-check (no XCTest in Command Line Tools). Run: ./test.sh
import Foundation
let existing: Set<String> = ["/src", "/src/a", "/src/a/b", "/src/c"]
precondition(Set(Watcher.roots(of: ["/src/a/b/", "/src/a/", "/src/c/gone/deeper/", "/other/"], under: "/src", exists: existing.contains)) == ["/src"])
precondition(Watcher.roots(of: ["/src/a/b/", "/src/a/", "/src/c/"], under: "/src", exists: existing.contains).sorted() == ["/src/a", "/src/c"])
precondition(Watcher.roots(of: ["/src/c/gone/"], under: "/src", exists: existing.contains) == ["/src/c"])

precondition(Store.problem(source: "/tmp/x", target: "/tmp/x") != nil)
precondition(Store.problem(source: "/tmp/x", target: "/tmp/x/y") != nil)
precondition(Store.problem(source: "/tmp/x/y", target: "/tmp/x") != nil)
precondition(Store.problem(source: "/tmp/x", target: "/tmp/xy") == nil)

precondition(Watcher.filters(fromIgnore: "# comment\n\nnode_modules/\n*.log\n!keep.log\ndocs/draft\n/build\n**/tmp\n") ==
    ["--exclude=**/tmp", "--exclude=/build", "--exclude=/docs/draft", "--include=keep.log", "--exclude=*.log", "--exclude=node_modules/"])

let delta = Watcher.countDelta("cd+++++++ a/\n>f+++++++ a/x.txt\n>f.st.... b.txt\n.d..t.... ./\n*deleting old/\n*deleting old/y.txt\n*deleting z.txt\n")
precondition(delta.files == -1 && delta.folders == 0)

precondition(TwoWay.listing(fromRsync: "drwxr-xr-x  128 2026/10/17 22:39:46 .\ndrwxr-xr-x   96 2026/10/17 22:39:46 sub\n-rw-r--r--    3 2026/10/17 22:39:46 sub/my file.txt\nlrwxr-xr-x    5 2026/10/17 22:39:46 ln -> other\n-rw-r--r--      2026/10/17 22:39:46 sub/empty note.md\n") ==
    ["sub": "dir", "sub/my file.txt": "3 2026/10/17 22:39:46", "ln": "link 5", "sub/empty note.md": "0 2026/10/17 22:39:46"])

let last: TwoWay.Listing = ["d": "dir", "d/kept": "1", "gone": "1", "edited": "1", "both": "1"]
let a: TwoWay.Listing = ["d": "dir", "d/kept": "1", "gone": "1", "edited": "1", "both": "2", "new": "1"]
let b: TwoWay.Listing = ["d": "dir", "d/kept": "1", "edited": "2", "both": "3"]
precondition(TwoWay.plan(a: a, b: b, last: last) == [.conflict("both"), .copy("edited", toB: false), .delete("gone", onA: true), .copy("new", toB: true)])

// Folder deleted on B while A added a file in it: folder stays, new file goes to B.
let dirPlan = TwoWay.plan(a: ["d": "dir", "d/old": "1", "d/new": "1"], b: [:], last: ["d": "dir", "d/old": "1"])
precondition(dirPlan == [.copy("d/new", toB: true), .delete("d/old", onA: true)])

// syncs.json saved before two-way existed still loads.
let oldJSON = #"[{"id":"9E8A1F1C-5B7E-4F0A-9C55-1D2E3F4A5B6C","source":"/a","target":"/b","createTarget":true}]"#
precondition((try! JSONDecoder().decode([SyncItem].self, from: Data(oldJSON.utf8)))[0].twoWay == false)

precondition(TwoWay.listing(fromRsync: "-rw-r--r--  1,234 2026/10/17 22:39:46 x\n") == nil, "unknown line fails closed")

// No snapshot (first run) never deletes.
precondition(TwoWay.plan(a: ["x": "1"], b: ["y": "1", "x": "2"], last: [:]) == [.conflict("x"), .copy("y", toB: false)])
// Two-way end to end on real folders.
let fm = FileManager.default
let root = NSTemporaryDirectory() + "FileSyncTest-\(UUID())"
let A = root + "/A", B = root + "/B"
try! fm.createDirectory(atPath: A + "/d", withIntermediateDirectories: true)
func w(_ p: String, _ s: String, ago: Double = 0) { try! s.write(toFile: p, atomically: false, encoding: .utf8); try! fm.setAttributes([.modificationDate: Date().addingTimeInterval(-ago)], ofItemAtPath: p) }
func r(_ p: String) -> String? { try? String(contentsOfFile: p, encoding: .utf8) }
w(A + "/a.txt", "a"); w(A + "/d/x.txt", "x"); w(A + "/skip.log", "log")
let item = SyncItem(source: A, target: B, createTarget: true, twoWay: true)
var lastStatus = ""
let watcher = Watcher(item: item, filters: Watcher.filters(fromIgnore: "*.log")) { lastStatus = $0 } onCounts: { _ in }
func pass() { watcher.syncAll(); Thread.sleep(forTimeInterval: 1.5) }
Thread.sleep(forTimeInterval: 1.5)
precondition(r(B + "/a.txt") == "a" && r(B + "/d/x.txt") == "x" && r(B + "/skip.log") == nil, "initial copy")
w(B + "/b.txt", "b"); pass()
precondition(r(A + "/b.txt") == "b", "B->A copy")
try! fm.removeItem(atPath: B + "/a.txt"); pass()
precondition(!fm.fileExists(atPath: A + "/a.txt"), "delete propagates")
w(A + "/b.txt", "old", ago: 100); w(B + "/b.txt", "new"); pass(); pass()
precondition(r(A + "/b.txt") == "new" && r(B + "/b.txt") == "new", "newest wins")
precondition(r(A + "/b (conflict).txt") == "old" && r(B + "/b (conflict).txt") == "old", "conflict copy kept on both")
w(A + "/b.txt", "same", ago: 100); w(B + "/b.txt", "same"); pass()
precondition(!fm.fileExists(atPath: A + "/b (conflict 2).txt") && !fm.fileExists(atPath: B + "/b (conflict 2).txt"), "same content is no conflict")
try! fm.removeItem(atPath: B + "/d"); w(A + "/d/new.txt", "n", ago: -5); pass(); pass()
precondition(r(B + "/d/new.txt") == "n" && !fm.fileExists(atPath: A + "/d/x.txt"), "folder delete vs new file")
for f in try! fm.contentsOfDirectory(atPath: B) { try! fm.removeItem(atPath: B + "/" + f) }
pass()
precondition(lastStatus == "Target is empty, not syncing" && fm.fileExists(atPath: A + "/d/new.txt"), "empty guard")
watcher.stop(); Watcher.forget(item)
try? fm.removeItem(atPath: root)

print("All checks passed")
