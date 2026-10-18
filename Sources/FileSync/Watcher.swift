import Foundation

struct Counts {
    var files = 0
    var folders = 0
}

/// Watches one sync's source with FSEvents and mirrors changed folders to the target via rsync.
final class Watcher {
    let item: SyncItem
    private let source: String
    private var filters: [String]
    private var counts: Counts
    private let onStatus: (String) -> Void
    private let onCounts: (Counts) -> Void
    private let queue = DispatchQueue(label: "FileSync.watcher", qos: .utility)
    private var stream: FSEventStreamRef?
    private var stopped = false
    private var needsFull = false
    private var eventIdKey: String { Self.eventIdKey(item) }
    private var countsKey: String { Self.countsKey(item) }

    init(item: SyncItem, filters: [String], onStatus: @escaping (String) -> Void, onCounts: @escaping (Counts) -> Void) {
        self.item = item
        self.source = URL(fileURLWithPath: item.source).resolvingSymlinksInPath().path
        self.filters = filters
        self.onStatus = onStatus
        self.onCounts = onCounts
        let saved = UserDefaults.standard.array(forKey: Self.countsKey(item)) as? [Int] ?? []
        self.counts = saved.count == 2 ? Counts(files: saved[0], folders: saved[1]) : Counts()
        self.needsFull = saved.count != 2
        onCounts(counts)
        queue.async { self.start() }
    }

    /// Full sync; pass `filters` to apply new ignore rules first.
    func syncAll(filters: [String]? = nil) {
        queue.async {
            if let filters { self.filters = filters }
            if !self.stopped { self.needsFull = !self.fullSync() }
        }
    }

    private func fullSync() -> Bool { item.twoWay ? syncTwoWay() : sync(source) }

    func stop() {
        queue.async {
            self.stopped = true
            if let stream = self.stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            self.stream = nil
        }
    }

    /// Drops the saved FSEvents position so a re-added sync starts with a full copy.
    static func forget(_ item: SyncItem) {
        UserDefaults.standard.removeObject(forKey: eventIdKey(item))
        UserDefaults.standard.removeObject(forKey: countsKey(item))
        try? FileManager.default.removeItem(at: snapshotURL(item))
    }

    private static func eventIdKey(_ item: SyncItem) -> String { "lastEventId.\(item.id)" }
    private static func countsKey(_ item: SyncItem) -> String { "counts.\(item.id)" }
    private static func snapshotURL(_ item: SyncItem) -> URL { .applicationSupportDirectory.appending(path: "File Sync/\(item.id).json") }

    /// Turns gitignore-style lines into rsync filter args (rsync is first-match-wins, gitignore last-match-wins).
    static func filters(fromIgnore text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).reversed().compactMap { line in
            var pattern = line.trimmingCharacters(in: .whitespaces)
            if pattern.isEmpty || pattern.hasPrefix("#") { return nil }
            let include = pattern.hasPrefix("!")
            if include { pattern.removeFirst() }

            // gitignore anchors patterns with an inner slash; rsync would match them at any depth.
            if !pattern.hasPrefix("/") && !pattern.hasPrefix("**/") && pattern.dropLast().contains("/") { pattern = "/" + pattern }
            return (include ? "--include=" : "--exclude=") + pattern
        }
    }

    /// Net files/folders created minus deleted, from `rsync -i` output.
    static func countDelta(_ output: String) -> Counts {
        var delta = Counts()
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("cd+++") {
                delta.folders += 1
            } else if line.hasPrefix(">f+++") || line.hasPrefix("cL+++") {
                delta.files += 1
            } else if line.hasPrefix("*deleting ") {
                if line.hasSuffix("/") { delta.folders -= 1 } else { delta.files -= 1 }
            }
        }
        return delta
    }

    private func start() {
        var since = UserDefaults.standard.object(forKey: eventIdKey) as? UInt64

        if item.twoWay {
            // Each two-way pass compares whole trees, so no event history is needed.
            since = FSEventsGetCurrentEventId()
            _ = syncTwoWay()
        } else if since == nil {
            // First run: full copy, then only changes from this point on.
            let now = FSEventsGetCurrentEventId()
            needsFull = !sync(source)
            if !needsFull { UserDefaults.standard.set(now, forKey: eventIdKey) }
            since = now
        } else if needsFull {
            // No saved counts yet (sync predates them): recount via a full run.
            needsFull = !sync(source)
        }

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            let watcher = Unmanaged<Watcher>.fromOpaque(info!).takeUnretainedValue()
            let paths = unsafeBitCast(paths, to: NSArray.self) as! [String]
            watcher.handle(paths: paths, flags: Array(UnsafeBufferPointer(start: flags, count: count)), lastId: ids[count - 1])
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        let watched = item.twoWay ? [item.source, item.target] : [item.source]
        guard let stream = FSEventStreamCreate(nil, callback, &context, watched as CFArray, since!, 2.0, flags) else {
            return onStatus("Could not watch source")
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    private func handle(paths: [String], flags: [FSEventStreamEventFlags], lastId: FSEventStreamEventId) {
        if item.twoWay { _ = syncTwoWay(); return }

        let fullScan = FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged)
        let historyDone = FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)
        if flags.contains(where: { $0 & fullScan != 0 }) { needsFull = true }

        let changed = zip(paths, flags).filter { $0.1 & historyDone == 0 }.map(\.0)
        let roots = needsFull ? [source] : Self.roots(of: changed, under: source)
        let ok = roots.allSatisfy(sync)
        needsFull = !ok
        if ok { UserDefaults.standard.set(lastId, forKey: eventIdKey) }
    }

    /// Smallest set of existing folders under `source` covering every changed path.
    static func roots(of paths: [String], under source: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String] {
        let dirs = paths.map { path -> String in
            var dir = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
            guard dir == source || dir.hasPrefix(source + "/") else { return source }
            while dir != source && !exists(dir) { dir = (dir as NSString).deletingLastPathComponent }
            return dir
        }
        var result: [String] = []
        for dir in Set(dirs).sorted(by: { $0.count < $1.count }) where !result.contains(where: { dir == $0 || dir.hasPrefix($0 + "/") }) {
            result.append(dir)
        }
        return result
    }

    /// rsyncs one source folder (recursive) to the target. Always runs from the source root so anchored ignore patterns match.
    private func sync(_ dir: String) -> Bool {
        guard ensureFolders() else { return false }

        // Limit the run to `dir`; names with wildcard characters can't be scoped, so they get a full run.
        let rel = String(dir.dropFirst(source.count))
        let full = rel.isEmpty || rel.contains(where: { "*?[\\".contains($0) })
        var args = ["-ai", "--delete"] + filters
        if !full {
            var path = ""
            for part in rel.split(separator: "/") {
                path += "/" + part
                args.append("--include=\(path)/")
            }
            args += ["--include=\(rel)/**", "--exclude=*"]
        }
        args += [source + "/", item.target + "/"]
        guard let output = rsync(args) else { return false }

        // shortcut: incremental counts drift if the target is edited by hand; any full sync recounts.
        if full {
            counts = countTarget()
        } else {
            let delta = Self.countDelta(output)
            counts.files = max(0, counts.files + delta.files)
            counts.folders = max(0, counts.folders + delta.folders)
        }
        finish()
        return true
    }

    /// One two-way pass over both whole trees.
    /// shortcut: rescans both trees on every change; scope to changed folders if large trees get slow.
    private func syncTwoWay() -> Bool {
        guard ensureFolders() else { return false }
        let target = item.target
        guard let a = list(source), let b = list(target) else { return false }
        let last = (try? JSONDecoder().decode(TwoWay.Listing.self, from: Data(contentsOf: Self.snapshotURL(item)))) ?? [:]

        // An unmounted or wiped side would otherwise delete everything on the other side.
        if !last.isEmpty && (a.isEmpty || b.isEmpty) {
            onStatus((a.isEmpty ? "Source" : "Target") + " is empty, not syncing")
            return false
        }

        let fm = FileManager.default
        var toA: [String] = [], toB: [String] = [], deletes: [String] = []
        for action in TwoWay.plan(a: a, b: b, last: last) {
            switch action {
            case .copy(let path, let toBSide):
                if toBSide { toB.append(path) } else { toA.append(path) }
            case .delete(let path, let onA):
                deletes.append((onA ? source : target) + "/" + path)
            case .conflict(let path):
                let mtime = { (root: String) in (try? fm.attributesOfItem(atPath: root + "/" + path)[.modificationDate] as? Date) ?? .distantPast }
                let aWins = mtime(source) >= mtime(target)
                guard keepConflictCopy((aWins ? target : source) + "/" + path) else { return false }
                if aWins { toB.append(path) } else { toA.append(path) }
            }
        }

        guard copy(toB, from: source, to: target), copy(toA, from: target, to: source) else { return false }

        // Deepest first, so a folder's files go before the folder.
        for path in deletes.sorted(by: { $0.count > $1.count }) where fm.fileExists(atPath: path) {
            do {
                try fm.removeItem(atPath: path)
            } catch {
                onStatus(error.localizedDescription)
                return false
            }
        }

        // Snapshot only what matches on both sides, so one-sided leftovers (e.g. a conflict copy) aren't taken as deleted.
        guard let nowA = list(source), let nowB = list(target) else { return false }
        let now = nowA.filter { nowB[$0.key] == $0.value }
        do {
            try fm.createDirectory(at: Self.snapshotURL(item).deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(now).write(to: Self.snapshotURL(item), options: .atomic)
        } catch {
            onStatus("Could not save snapshot: \(error.localizedDescription)")
            return false
        }
        let folders = now.values.filter { $0 == "dir" }.count
        counts = Counts(files: now.count - folders, folders: folders)
        finish()
        return true
    }

    /// Lists one side, with ignore rules applied.
    private func list(_ root: String) -> TwoWay.Listing? {
        rsync(["-a", "--list-only"] + filters + [root + "/"]).map(TwoWay.listing(fromRsync:))
    }

    private func copy(_ paths: [String], from: String, to: String) -> Bool {
        paths.isEmpty || rsync(["-a", "--files-from=-", from + "/", to + "/"], input: paths.joined(separator: "\n") + "\n") != nil
    }

    /// Renames the losing side of a conflict to "name (conflict).ext", or "name (conflict 2).ext" if taken.
    private func keepConflictCopy(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var n = 1, dest: URL
        repeat {
            let name = base + (n == 1 ? " (conflict)" : " (conflict \(n))") + (ext.isEmpty ? "" : "." + ext)
            dest = url.deletingLastPathComponent().appending(path: name)
            n += 1
        } while FileManager.default.fileExists(atPath: dest.path)
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            return true
        } catch {
            onStatus(error.localizedDescription)
            return false
        }
    }

    /// Checks the source exists and creates the target if allowed.
    private func ensureFolders() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source) else { onStatus("Source folder missing"); return false }
        if !fm.fileExists(atPath: item.target) {
            guard item.createTarget else { onStatus("Target folder missing"); return false }
            do {
                try fm.createDirectory(atPath: item.target, withIntermediateDirectories: true)
            } catch {
                onStatus(error.localizedDescription)
                return false
            }
        }
        return true
    }

    /// Runs rsync and returns its output, or reports the error and returns nil.
    private func rsync(_ args: [String], input: String? = nil) -> String? {
        let rsync = Process()
        rsync.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        rsync.arguments = args
        rsync.qualityOfService = .background
        let pipe = Pipe()
        rsync.standardOutput = pipe
        rsync.standardError = pipe
        let stdin = Pipe()
        if input != nil { rsync.standardInput = stdin }
        do {
            try rsync.run()
        } catch {
            onStatus(error.localizedDescription)
            return nil
        }
        if let input {
            // If rsync exits early the write fails instead of SIGPIPE killing the app.
            signal(SIGPIPE, SIG_IGN)

            // Written from another queue so a full output pipe can't deadlock us.
            DispatchQueue.global().async {
                try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                try? stdin.fileHandleForWriting.close()
            }
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        rsync.waitUntilExit()

        guard rsync.terminationStatus == 0 else {
            let errors = output.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("rsync") || $0.contains("error") }
            onStatus("rsync failed: " + (errors.last.map(String.init) ?? "exit \(rsync.terminationStatus)"))
            return nil
        }
        return output
    }

    private func finish() {
        UserDefaults.standard.set([counts.files, counts.folders], forKey: countsKey)
        onCounts(counts)
        onStatus("Synced " + Date().formatted(date: .abbreviated, time: .shortened))
    }

    private func countTarget() -> Counts {
        var result = Counts()
        let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: item.target), includingPropertiesForKeys: [.isDirectoryKey])
        while let url = walker?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { result.folders += 1 } else { result.files += 1 }
        }
        return result
    }
}
