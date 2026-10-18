// Self-check (no XCTest in Command Line Tools). Run: ./test.sh
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
print("All checks passed")
