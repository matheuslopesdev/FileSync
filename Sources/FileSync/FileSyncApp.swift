import AppKit
import ServiceManagement
import SwiftUI

@main
struct FileSyncApp: App {
    @State private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store)
        } label: {
            Image(nsImage: menuIcon)
        }

        Window("File Sync", id: "main") {
            MainView(store: store)
        }
        .defaultLaunchBehavior(.suppressed)
    }
}

// Template image: macOS tints it to match the menu bar.
private let menuIcon: NSImage = {
    let image = NSImage(systemSymbolName: "arrow.left.and.right", accessibilityDescription: "File Sync")!.withSymbolConfiguration(.init(pointSize: 17, weight: .bold))!
    image.isTemplate = true
    return image
}()

struct MenuContent: View {
    let store: Store
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Button("Open File Sync…") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("Sync All Now") { store.syncAll() }
        Toggle("Launch at Login", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) { _, enabled in
                if enabled {
                    try? SMAppService.mainApp.register()
                } else {
                    try? SMAppService.mainApp.unregister()
                }
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }
}

struct MainView: View {
    let store: Store
    @State private var adding = false

    var body: some View {
        TabView {
            Tab("Syncs", systemImage: "arrow.left.and.right") { syncList }
            Tab("Ignore", systemImage: "eye.slash") { IgnoreView(store: store) }
        }
        .safeAreaInset(edge: .bottom) {
            if !store.message.isEmpty {
                Text(store.message).font(.caption).foregroundStyle(.secondary).padding(6)
            }
        }
        .toolbar {
            Button { adding = true } label: { Image(systemName: "plus") }
                .help("Add sync")
                .disabled(store.loadFailed)
        }
        .sheet(isPresented: $adding) { AddSyncView(store: store) }
        .frame(minWidth: 560, minHeight: 320)
    }

    private var syncList: some View {
        List(store.syncs) { item in
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(item.source) \(Text(item.twoWay ? "↔" : "→").foregroundStyle(.secondary)) \(item.target)").lineLimit(1).truncationMode(.middle)
                    Text(details(item)).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                Button { store.syncNow(item) } label: { Image(systemName: "arrow.clockwise") }
                    .help("Sync now")
                Button { store.remove(item) } label: { Image(systemName: "trash") }
                    .help("Remove sync (files are kept)")
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 4)
        }
        .overlay {
            if store.syncs.isEmpty {
                ContentUnavailableView("No Syncs", systemImage: "arrow.left.and.right", description: Text("Click + to add a folder sync."))
            }
        }
    }

    private func details(_ item: SyncItem) -> String {
        let status = store.status[item.id] ?? "Waiting…"
        guard let counts = store.counts[item.id] else { return status }
        return "\(counts.files.formatted()) files · \(counts.folders.formatted()) folders · \(status)"
    }
}

struct IgnoreView: View {
    let store: Store
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("One pattern per line, like .gitignore. Applies to every sync. `#` comment, `!` re-include, leading `/` anchors to the source folder, trailing `/` matches folders only.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(.background.secondary, in: .rect(cornerRadius: 6))
            HStack {
                Text("Ignored files already in a target are left there.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save") { store.saveIgnore(text) }
                    .keyboardShortcut("s")
                    .disabled(text == store.ignoreText)
            }
        }
        .padding()
        .onAppear { text = store.ignoreText }
    }
}

struct AddSyncView: View {
    let store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var target = ""
    @State private var createTarget = true
    @State private var twoWay = false

    private var sourcePath: String { (source as NSString).expandingTildeInPath }
    private var targetPath: String { (target as NSString).expandingTildeInPath }

    private var problem: String? {
        if source.isEmpty || target.isEmpty { return nil }
        if !sourcePath.hasPrefix("/") || !targetPath.hasPrefix("/") { return "Use absolute paths." }
        if !FileManager.default.fileExists(atPath: sourcePath) { return "Source folder does not exist." }
        return Store.problem(source: sourcePath, target: targetPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Sync").font(.headline)
            folderField("Source", text: $source)
            folderField("Target", text: $target)
            Toggle("Create target folder if it doesn't exist", isOn: $createTarget)
            Toggle("Two-way sync", isOn: $twoWay)
            Label(twoWay ? "Changes and deletions on either side are copied to the other. Conflicts keep both versions."
                         : "Target becomes a mirror: files not in the source are deleted from it.", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    store.add(SyncItem(source: sourcePath, target: targetPath, createTarget: createTarget, twoWay: twoWay))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(source.isEmpty || target.isEmpty || problem != nil)
            }
        }
        .padding()
        .frame(width: 480)
    }

    private func folderField(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title).frame(width: 50, alignment: .leading)
            TextField(title, text: text, prompt: Text("\(title) folder path"))
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.canCreateDirectories = true
                if panel.runModal() == .OK, let url = panel.url { text.wrappedValue = url.path }
            }
        }
    }
}
