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

    /// Parses `rsync -a --list-only` output.
    static func listing(fromRsync output: String) -> Listing {
        var result = Listing()
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count == 5, parts[4] != "." else { continue }
            var path = String(parts[4])
            switch parts[0].first {
            case "d":
                result[path] = "dir"
            case "l":
                if let arrow = path.range(of: " -> ") { path = String(path[..<arrow.lowerBound]) }

                // Symlink mtimes aren't reliably preserved, so compare size only.
                result[path] = "link \(parts[1])"
            default:
                result[path] = "\(parts[1]) \(parts[2]) \(parts[3])"
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
