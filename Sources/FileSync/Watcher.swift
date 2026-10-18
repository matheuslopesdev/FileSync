import Foundation

/// Watches one sync's source with FSEvents and mirrors changed folders to the target via rsync.
final class Watcher {
    let item: SyncItem
    private let source: String
    private let onStatus: (String) -> Void
    private let queue = DispatchQueue(label: "FileSync.watcher", qos: .utility)
    private var stream: FSEventStreamRef?
    private var stopped = false
    private var needsFull = false
    private var eventIdKey: String { Self.eventIdKey(item) }

    init(item: SyncItem, onStatus: @escaping (String) -> Void) {
        self.item = item
        self.source = URL(fileURLWithPath: item.source).resolvingSymlinksInPath().path
        self.onStatus = onStatus
        queue.async { self.start() }
    }

    func syncAll() {
        queue.async { if !self.stopped { self.needsFull = !self.sync(self.source) } }
    }

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
    }

    private static func eventIdKey(_ item: SyncItem) -> String { "lastEventId.\(item.id)" }

    private func start() {
        var since = UserDefaults.standard.object(forKey: eventIdKey) as? UInt64

        // First run: full copy, then only changes from this point on.
        if since == nil {
            let now = FSEventsGetCurrentEventId()
            needsFull = !sync(source)
            if !needsFull { UserDefaults.standard.set(now, forKey: eventIdKey) }
            since = now
        }

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            let watcher = Unmanaged<Watcher>.fromOpaque(info!).takeUnretainedValue()
            let paths = unsafeBitCast(paths, to: NSArray.self) as! [String]
            watcher.handle(paths: paths, flags: Array(UnsafeBufferPointer(start: flags, count: count)), lastId: ids[count - 1])
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [item.source] as CFArray, since!, 2.0, flags) else {
            return onStatus("Could not watch source")
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    private func handle(paths: [String], flags: [FSEventStreamEventFlags], lastId: FSEventStreamEventId) {
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

    /// rsyncs one source folder (recursive) to its mirror in the target.
    private func sync(_ dir: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source) else { onStatus("Source folder missing"); return false }
        if !fm.fileExists(atPath: item.target) && !item.createTarget { onStatus("Target folder missing"); return false }

        let dest = item.target + dir.dropFirst(source.count)
        do {
            try fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
        } catch {
            onStatus(error.localizedDescription)
            return false
        }

        let rsync = Process()
        rsync.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        rsync.arguments = ["-a", "--delete", dir + "/", dest + "/"]
        rsync.qualityOfService = .background
        let stderr = Pipe()
        rsync.standardError = stderr
        rsync.standardOutput = FileHandle.nullDevice
        do {
            try rsync.run()
        } catch {
            onStatus(error.localizedDescription)
            return false
        }
        let output = stderr.fileHandleForReading.readDataToEndOfFile()
        rsync.waitUntilExit()

        guard rsync.terminationStatus == 0 else {
            onStatus("rsync failed: " + String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            return false
        }
        onStatus("Synced " + Date().formatted(date: .abbreviated, time: .shortened))
        return true
    }
}
