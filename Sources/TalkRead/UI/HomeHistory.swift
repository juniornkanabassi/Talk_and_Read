// Home's History: what was read aloud and what was dictated, merged, newest first, grouped by day, each row with the
// app it happened in and that app's icon (resolved at display time, as Speechify does; nothing of its code is used).
import AppKit
import SwiftUI
import TalkReadCore

// MARK: - App icons

/// Icons by bundle id (or by name for old entries), resolved lazily and cached for the life of the app. The slow part
/// (Launch Services and folder probing) runs off the main thread; only the cheap `icon(forFile:)` runs on it.
@MainActor enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    private static var inflight: [String: Task<URL?, Never>] = [:]

    static func key(_ name: String?, _ bundleID: String?) -> String { bundleID ?? "name:" + (name ?? "") }
    static func cached(_ name: String?, _ bundleID: String?) -> NSImage? { cache[key(name, bundleID)] }

    static func load(_ name: String?, _ bundleID: String?) async -> NSImage {
        let k = key(name, bundleID)
        if let hit = cache[k] { return hit }
        if name == ownAppName || (bundleID != nil && bundleID == Bundle.main.bundleIdentifier), let own = NSApp.applicationIconImage {
            cache[k] = own
            return own
        }
        let lookup = inflight[k] ?? Task.detached(priority: .utility) { appURL(name, bundleID) }
        inflight[k] = lookup
        let url = await lookup.value
        inflight[k] = nil
        let image = cache[k] ?? url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .applicationBundle)
        cache[k] = image
        return image
    }

    /// Bundle id first; for old entries (a name only) `<name>.app` in the usual folders.
    nonisolated static func appURL(_ name: String?, _ bundleID: String?) -> URL? {
        if let id = bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        guard let name, !name.isEmpty, !name.contains("/") else { return nil }
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        return folders.map { URL(fileURLWithPath: $0).appendingPathComponent(name + ".app") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

struct AppIconView: View {
    let name: String?
    let bundleID: String?
    @State private var loaded: NSImage?

    var body: some View {
        Group {
            if let image = loaded ?? AppIcons.cached(name, bundleID) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Color.clear
            }
        }
        .frame(width: 16, height: 16)
        .task(id: AppIcons.key(name, bundleID)) { loaded = await AppIcons.load(name, bundleID) }
        .accessibilityHidden(true)
    }
}

// MARK: - History section

enum HistoryFilter: String, CaseIterable, Identifiable {
    case all = "All", read = "Read", dictated = "Dictated"
    var id: Self { self }
    var kind: HistoryKind? { self == .read ? .read : self == .dictated ? .dictated : nil }
}

struct HomeHistory: View {
    @ObservedObject var model: AppModel
    let data: ViewData
    @State private var filter: HistoryFilter
    @State private var search: String
    @State private var shown: Int
    /// Snapshots only: the row drawn as if the pointer were over it, and a short page to show the Show more button.
    let hoveredID: UUID?
    let pageSize: Int

    init(model: AppModel, data: ViewData, filter: HistoryFilter = .all, search: String = "", hoveredID: UUID? = nil, pageSize: Int = History.pageSize) {
        self.model = model
        self.data = data
        self.hoveredID = hoveredID
        self.pageSize = pageSize
        _filter = State(initialValue: filter)
        _search = State(initialValue: search)
        _shown = State(initialValue: pageSize)
    }

    var body: some View {
        let everything = History.merge(data.recentReads.map(\.historyItem) + data.dictations.map(\.historyItem))
        let matches = History.filter(everything, kind: filter.kind, search: search)
        let sections = History.sections(matches, limit: shown)
        VStack(alignment: .leading, spacing: 14) {
            header
            if everything.isEmpty {
                EmptyNote(text: Self.emptyText(model.settings)).card(padding: 0)
            } else if matches.isEmpty {
                EmptyNote(text: "No matching history").card(padding: 0)
            } else {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.leading, 4).accessibilityAddTraits(.isHeader)
                        VStack(spacing: 0) {
                            ForEach(section.items) { item in
                                HistoryRow(model: model, item: item, forceActions: item.id == hoveredID)
                                if item.id != section.items.last?.id { Divider().padding(.leading, 14) }
                            }
                        }
                        .card(padding: 0)
                    }
                }
                if matches.count > shown {
                    Button("Show more") { shown += pageSize }
                        .buttonStyle(.bordered).controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Show \(min(pageSize, matches.count - shown)) more entries")
                }
            }
        }
        .onChange(of: filter) { shown = pageSize }
        .onChange(of: search) { shown = pageSize }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("History").font(.headline)
            Spacer(minLength: 8)
            Picker("Show", selection: $filter) {
                ForEach(HistoryFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 230)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search history", text: $search).textFieldStyle(.plain)
                    .accessibilityLabel("Search history")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(width: 210)
            .background(Color.primary.opacity(0.06), in: Capsule())
        }
    }

    /// "Nothing here yet. Select text and press ⌃A to listen, or hold the right Option key and speak to dictate."
    static func emptyText(_ s: TalkReadCore.Settings) -> String {
        let read = s.readShortcut.display.isEmpty ? "Select text to listen" : "Select text and press \(s.readShortcut.display) to listen"
        let hold = holdHint(s)
        return "Nothing here yet. \(read), or \(hold.prefix(1).lowercased() + hold.dropFirst()) to dictate."
    }
}

// MARK: - Row

struct HistoryRow: View {
    @ObservedObject var model: AppModel
    let item: HistoryItem
    var forceActions = false
    @State private var hovering = false
    @State private var expanded = false
    @State private var confirmingDelete = false
    @State private var fullHeight: CGFloat = 0
    @State private var threeLines: CGFloat = 0
    @FocusState private var focus: Action?

    enum Action { case again, copy, delete }

    private var canExpand: Bool { fullHeight > threeLines + 1 }
    private var showActions: Bool { hovering || forceActions || focus != nil }
    private var verb: String {
        switch (item.kind, item.app) {
        case (.read, _): "Read in"
        case (.dictated, nil): "Dictated"
        case (.dictated, _): "Dictated in"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(verb).foregroundStyle(.secondary)
                if let app = item.app {
                    AppIconView(name: app, bundleID: item.bundleID)
                    Text(app).fontWeight(.medium).lineLimit(1)
                }
                Text(History.time(item.date)).monospacedDigit().foregroundStyle(.secondary).padding(.leading, 4)
                Spacer(minLength: 8)
                actions.opacity(showActions ? 1 : 0)
            }
            .font(.callout)
            text
            if canExpand {
                Button(expanded ? "Show less" : "Show more") { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }
                    .buttonStyle(.plain).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if item.kind == .read { Button("Read again", action: readAgain) }
            Button("Copy", action: copy)
            Divider()
            Button("Delete…", role: .destructive) { confirmingDelete = true }
        }
        .alert("Delete this entry?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: delete)
        } message: {
            Text("It is removed from this Mac and cannot be undone.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(verb) \(item.app ?? ""), \(History.time(item.date))")
    }

    private var text: some View {
        Text(item.text)
            .lineLimit(expanded ? nil : 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .topLeading) {
                // Unseen copies measure the full height (800 characters are always more than three lines) and three lines.
                ZStack {
                    Text(String(item.text.prefix(800))).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                    Text("A\nA\nA").fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { threeLines = $0 }
                }
                .hidden().accessibilityHidden(true)
            }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if item.kind == .read {
                Button(action: readAgain) { Image(systemName: "play.circle") }
                    .help("Read again").accessibilityLabel("Read again").focused($focus, equals: .again)
            }
            CopyButton(text: item.text).focused($focus, equals: .copy)
            Button { confirmingDelete = true } label: { Image(systemName: "trash") }
                .help("Delete").accessibilityLabel("Delete").focused($focus, equals: .delete)
        }
        .buttonStyle(.borderless).foregroundStyle(.secondary)
    }

    private func readAgain() { try? model.speak(item.text, title: nil, caller: "user") }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
    }

    private func delete() {
        if item.kind == .read { model.deleteRead(item.id) } else { model.deleteDictation(item.id) }
    }
}
