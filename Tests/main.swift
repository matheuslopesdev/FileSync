// Self-check (no XCTest in Command Line Tools). Run: ./test.sh
let existing: Set<String> = ["/src", "/src/a", "/src/a/b", "/src/c"]
precondition(Set(Watcher.roots(of: ["/src/a/b/", "/src/a/", "/src/c/gone/deeper/", "/other/"], under: "/src", exists: existing.contains)) == ["/src"])
precondition(Watcher.roots(of: ["/src/a/b/", "/src/a/", "/src/c/"], under: "/src", exists: existing.contains).sorted() == ["/src/a", "/src/c"])
precondition(Watcher.roots(of: ["/src/c/gone/"], under: "/src", exists: existing.contains) == ["/src/c"])

precondition(Store.problem(source: "/tmp/x", target: "/tmp/x") != nil)
precondition(Store.problem(source: "/tmp/x", target: "/tmp/x/y") != nil)
precondition(Store.problem(source: "/tmp/x/y", target: "/tmp/x") != nil)
precondition(Store.problem(source: "/tmp/x", target: "/tmp/xy") == nil)
print("All checks passed")
