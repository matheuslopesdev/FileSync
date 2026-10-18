import Foundation
import Observation

struct SyncItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var source: String
    var target: String
    var createTarget: Bool
    var twoWay = false
}

// In an extension to keep the memberwise init.
extension SyncItem {
    /// Tolerates syncs.json files saved before `twoWay` existed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        source = try c.decode(String.self, forKey: .source)
        target = try c.decode(String.self, forKey: .target)
        createTarget = try c.decode(Bool.self, forKey: .createTarget)
        twoWay = try c.decodeIfPresent(Bool.self, forKey: .twoWay) ?? false
    }
}

/// Owns the sync list and persists it to syncs.json in iCloud Drive.
@MainActor @Observable
final class Store {
    var syncs: [SyncItem] = []
    var status: [UUID: String] = [:]
    var counts: [UUID: Counts] = [:]
    var ignoreText = ""
    var message = ""
    var loadFailed = false
    private var watchers: [UUID: Watcher] = [:]
    private let configDir = URL.libraryDirectory.appending(path: "Mobile Documents/com~apple~CloudDocs/File Sync")
    private var configURL: URL { configDir.appending(path: "syncs.json") }
    private var ignoreURL: URL { configDir.appending(path: "ignore.txt") }

    init() {
        ignoreText = (try? String(contentsOf: ignoreURL, encoding: .utf8)) ?? ""
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
        counts[item.id] = nil
        save()
    }

    func syncNow(_ item: SyncItem) { watchers[item.id]?.syncAll() }

    func syncAll() { watchers.values.forEach { $0.syncAll() } }

    /// Saves ignore.txt to iCloud and re-runs every sync with the new rules.
    func saveIgnore(_ text: String) {
        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            try text.write(to: ignoreURL, atomically: true, encoding: .utf8)
        } catch {
            message = "Save failed: \(error.localizedDescription)"
            return
        }
        ignoreText = text
        let filters = Watcher.filters(fromIgnore: text)
        watchers.values.forEach { $0.syncAll(filters: filters) }
    }

    /// Rejects pairs where rsync --delete could wipe the source or loop forever.
    nonisolated static func problem(source: String, target: String) -> String? {
        let resolve = { (p: String) in URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path + "/" }
        let s = resolve(source), t = resolve(target)
        if s.hasPrefix(t) || t.hasPrefix(s) { return "Source and target must not be the same folder or inside each other." }
        return nil
    }

    private func watch(_ item: SyncItem) {
        let id = item.id
        watchers[id] = Watcher(item: item, filters: Watcher.filters(fromIgnore: ignoreText)) { text in
            Task { @MainActor [weak self] in self?.status[id] = text }
        } onCounts: { counts in
            Task { @MainActor [weak self] in self?.counts[id] = counts }
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
