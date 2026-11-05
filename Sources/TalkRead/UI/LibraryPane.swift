import AppKit
import SwiftUI
import TalkReadCore

// MARK: - Library

struct LibraryPane: View {
    @ObservedObject var model: AppModel
    let data: ViewData
    @ObservedObject var router: WindowRouter
    @Environment(\.undoManager) private var undoManager
    @Environment(\.offscreenRender) private var offscreen
    @State private var counts = LibraryPane.tokenCounts

    // ponytail: process-lifetime word-count cache for progress; documents don't change after import.
    private static var tokenCounts: [UUID: Int] = [:]

    var body: some View {
        NavigationStack(path: $router.libraryPath) {
            grid
                .navigationTitle("Library")
                .navigationDestination(for: LibraryItem.self) { ReaderView(model: model, item: $0, data: data) }
                .toolbar {
                    ToolbarItemGroup {
                        Button("Open web page…", systemImage: "globe") { router.openWebPage() }
                            .help("Open a web page (⇧⌘L)")
                        Button("Open file…", systemImage: "doc.badge.plus") { router.chooseFiles(into: model) }
                            .help("Open files (⌘O)")
                    }
                }
        }
        .fileImporter(isPresented: $router.choosingFiles, allowedContentTypes: Importer.contentTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { router.importFiles(urls, into: model) }
        }
        .sheet(isPresented: $router.askingAddress) { WebPageSheet(model: model, router: router) }
    }

    @ViewBuilder private var grid: some View {
        if data.library.isEmpty {
            ContentUnavailableView {
                Label("No documents yet", systemImage: "books.vertical")
            } description: {
                Text("Open a PDF, Word document, EPUB or web page, or drop files on this window.")
            } actions: {
                Button("Open file…") { router.chooseFiles(into: model) }.buttonStyle(AccentButtonStyle())
                Button("Open web page…") { router.openWebPage() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surface)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 300), spacing: Space.lg)], spacing: Space.lg) {
                    ForEach(data.library) { item in
                        NavigationLink(value: item) { LibraryCard(item: item, progress: progress(item)) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Read") { model.read(item, fromToken: item.position); router.open(item) }
                                Button("Read from the start") { model.read(item, fromToken: 0); router.open(item) }
                                Divider()
                                Button("Remove from library", role: .destructive) { model.remove(item, undoManager: undoManager) }
                            }
                    }
                }
                .padding(Space.spacious)
            }
            .background(Theme.surface)
            .task(id: data.library.map(\.id)) { await countWords() }
        }
    }

    private func progress(_ item: LibraryItem) -> Double? {
        guard let n = counts[item.id], n > 1 else { return nil }
        return min(1, Double(item.position) / Double(n - 1))
    }

    private func countWords() async {
        for item in data.library where Self.tokenCounts[item.id] == nil {
            let fixture = offscreen ? try? data.documentText(item) : nil
            let model = model
            let count = await Task.detached(priority: .utility) {
                guard let text = fixture ?? (try? model.documentText(item)) else { return nil as Int? }
                return TextKit.tokenize(text).count
            }.value
            guard !Task.isCancelled, let count else { return }
            Self.tokenCounts[item.id] = count
            counts = Self.tokenCounts
        }
    }
}

struct LibraryCard: View {
    let item: LibraryItem
    let progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .top) {
                IconTile(symbol: Theme.kindIcon(item.kind))
                Spacer()
                Text(Theme.kindName(item.kind)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            Text(item.title).font(.headline).lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading).help(item.title)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: Space.sm) {
                ThinBar(value: progress ?? 0)
                HStack {
                    Text(item.added, format: .dateTime.day().month(.abbreviated))
                    Spacer()
                    Text(progressLabel)
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(Space.lg)
        .frame(height: 168)
        .card(padding: 0)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens in the reader")
    }

    private var progressLabel: String {
        guard let p = progress else { return "" }
        if p <= 0 { return "Not started" }
        if p >= 0.995 { return "Finished" }
        return "\(Int((p * 100).rounded())) %"
    }
}

struct WebPageSheet: View {
    let model: AppModel
    let router: WindowRouter
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var loading = false
    @State private var failure: String?

    private var url: URL? { Self.address(address) }

    /// What the address field accepts, and `talkread open-url` too: an http or https address with a host; a bare host
    /// ("example.com/page") gets https.
    static func address(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let u = URL(string: t.contains("://") ? t : "https://" + t),
              ["http", "https"].contains(u.scheme?.lowercased() ?? ""), u.host != nil else { return nil }
        return u
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("Open a web page").font(.title3.weight(.semibold))
            Text("Talk & Read fetches the page once and keeps only its text on this Mac.").font(.callout).foregroundStyle(.secondary)
            TextField("Address", text: $address, prompt: Text("https://"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(open)
                .disabled(loading)
            if let failure { Text(failure).font(.callout).foregroundStyle(.red) }
            HStack {
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open", action: open).keyboardShortcut(.defaultAction).disabled(url == nil || loading)
            }
        }
        .padding(Space.xxl)
        .frame(width: 480)
    }

    private func open() {
        guard let url, !loading else { return }
        loading = true
        failure = nil
        Task {
            do {
                let item = try await model.importWebPage(url)
                dismiss()
                router.open(item)
            } catch {
                failure = error.localizedDescription
            }
            loading = false
        }
    }
}

