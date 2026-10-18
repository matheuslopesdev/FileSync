import Foundation
import Observation

struct SyncItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var source: String
    var target: String
    var createTarget: Bool
}

/// Owns the sync list, persists it to syncs.json next to the app, and commits it to git.
@MainActor @Observable
final class Store {
    var syncs: [SyncItem] = []
    var status: [UUID: String] = [:]
    var message = ""
    var loadFailed = false
    private var watchers: [UUID: Watcher] = [:]
    private let repo = Bundle.main.bundleURL.deletingLastPathComponent()
    private let gitQueue = DispatchQueue(label: "FileSync.git", qos: .utility)
    private var configURL: URL { repo.appending(path: "syncs.json") }

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
        save("Add sync \(item.source) -> \(item.target)")
    }

    func remove(_ item: SyncItem) {
        watchers.removeValue(forKey: item.id)?.stop()
        Watcher.forget(item)
        syncs.removeAll { $0.id == item.id }
        status[item.id] = nil
        save("Remove sync \(item.source) -> \(item.target)")
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

    private func save(_ commitMessage: String) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(syncs).write(to: configURL, options: .atomic)
        } catch {
            message = "Save failed: \(error.localizedDescription)"
            return
        }

        let repo = repo.path
        gitQueue.async {
            var result = "Saved and committed"
            do {
                try Self.git(repo, "add", "syncs.json")
                try Self.git(repo, "commit", "-m", commitMessage, "--", "syncs.json")
                if try !Self.git(repo, "remote").isEmpty {
                    try Self.git(repo, "push", "-u", "origin", "HEAD")
                    result = "Saved, committed and pushed"
                }
            } catch {
                result = "Git: \(error.localizedDescription)"
            }
            Task { @MainActor [weak self] in self?.message = result }
        }
    }

    @discardableResult
    nonisolated private static func git(_ repo: String, _ args: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "git", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: output])
        }
        return output
    }
}
