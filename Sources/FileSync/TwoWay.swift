import Foundation

/// Decides what a two-way pass must do by comparing both sides with the snapshot of the last pass.
enum TwoWay {
    /// Relative path -> fingerprint ("dir", "link <size>" or "<size> <date> <time>").
    typealias Listing = [String: String]

    enum Action: Equatable {
        case copy(String, toB: Bool)
        case delete(String, onA: Bool)
        case conflict(String)
    }

    // "<perms> <size> <date> <time> <path>"; openrsync leaves the size blank for empty files.
    private static let entry = try! NSRegularExpression(pattern: #"^(\S)\S*\s+(\d*)\s+(\d{4}/\d\d/\d\d \d\d:\d\d:\d\d) (.+)$"#)

    /// Parses `rsync -a --list-only` output; nil on any unknown line, since a skipped file would look deleted.
    static func listing(fromRsync output: String) -> Listing? {
        var result = Listing()
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            guard let m = entry.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
            let field = { (i: Int) in String(line[Range(m.range(at: i), in: line)!]) }
            var path = field(4)
            let size = field(2).isEmpty ? "0" : field(2)
            guard path != "." else { continue }
            switch field(1) {
            case "d":
                result[path] = "dir"
            case "l":
                if let arrow = path.range(of: " -> ") { path = String(path[..<arrow.lowerBound]) }

                // Symlink mtimes aren't reliably preserved, so compare size only.
                result[path] = "link \(size)"
            default:
                result[path] = "\(size) \(field(3))"
            }
        }
        return result
    }

    static func plan(a: Listing, b: Listing, last: Listing) -> [Action] {
        var actions: [Action] = []
        for path in Set(a.keys).union(b.keys).sorted() {
            let old = last[path]
            switch (a[path], b[path]) {
            case let (fa?, fb?) where fa == fb:
                continue
            case let (fa?, nil):
                // An edit wins over a delete on the other side.
                actions.append(old == nil || fa != old ? .copy(path, toB: true) : .delete(path, onA: true))
            case let (nil, fb?):
                actions.append(old == nil || fb != old ? .copy(path, toB: false) : .delete(path, onA: false))
            case let (fa?, fb?):
                if fb == old {
                    actions.append(.copy(path, toB: true))
                } else if fa == old {
                    actions.append(.copy(path, toB: false))
                } else {
                    actions.append(.conflict(path))
                }
            case (nil, nil):
                continue
            }
        }

        // Keep a deleted folder if a file inside it is still copied (added on one side after the delete).
        let copied = actions.compactMap { action -> String? in
            switch action {
            case .copy(let p, _), .conflict(let p): p
            case .delete: nil
            }
        }
        return actions.filter { action in
            guard case .delete(let dir, let onA) = action, (onA ? a : b)[dir] == "dir" else { return true }
            return !copied.contains { $0.hasPrefix(dir + "/") }
        }
    }
}
