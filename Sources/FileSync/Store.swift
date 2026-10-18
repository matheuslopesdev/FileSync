import Foundation
import Observation

struct SyncItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var source: String
    var target: String
    var createTarget: Bool
}

/// Owns the sync list and persists it to syncs.json in iCloud Drive.
@MainActor @Observable
final class Store {
    var syncs: [SyncItem] = []
    var status: [UUID: String] = [:]
    var message = ""
    var loadFailed = false
    private var watchers: [UUID: Watcher] = [:]
    private let configDir = URL.libraryDirectory.appending(path: "Mobile Documents/com~apple~CloudDocs/File Sync")
    private var configURL: URL { configDir.appending(path: "syncs.json") }

    init() {
        if FileManager.default.fileExists(atPath: configURL.path) {
            do {
                syncs = try JSONDecoder().decode([SyncItem].self, from: Data(contentsOf: configURL))
            } catch {
                loadFailed = true
                message = "Could not read syncs.json: \(error.localizedDescription)"
            }
        }
        syncs.forEach(watch)
    }

    func add(_ item: SyncItem) {
        syncs.append(item)
        watch(item)
        save()
    }

    func remove(_ item: SyncItem) {
        watchers.removeValue(forKey: item.id)?.stop()
        Watcher.forget(item)
        syncs.removeAll { $0.id == item.id }
        status[item.id] = nil
        save()
    }

    func syncNow(_ item: SyncItem) { watchers[item.id]?.syncAll() }

    func syncAll() { watchers.values.forEach { $0.syncAll() } }

    /// Rejects pairs where rsync --delete could wipe the source or loop forever.
    nonisolated static func problem(source: String, target: String) -> String? {
        let resolve = { (p: String) in URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path + "/" }
        let s = resolve(source), t = resolve(target)
        if s.hasPrefix(t) || t.hasPrefix(s) { return "Source and target must not be the same folder or inside each other." }
        return nil
    }

    private func watch(_ item: SyncItem) {
        let id = item.id
        watchers[id] = Watcher(item: item) { text in
            Task { @MainActor [weak self] in self?.status[id] = text }
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(syncs).write(to: configURL, options: .atomic)
            message = ""
        } catch {
            message = "Save failed: \(error.localizedDescription)"
        }
    }
}
