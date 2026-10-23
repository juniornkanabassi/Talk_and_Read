// Main window: sidebar (Home, Library, Dictation, Voices, Settings) and its panes. Owned by WP6.
// Live views bind to AppModel; each pane takes a `ViewData` value so the offscreen snapshots can show sample data
// (AppModel's published state is read-only from outside its file).
import AppKit
import SwiftUI
import TalkReadCore

/// What the window shows. Live: `AppModel.viewData`. Snapshots: sample data.
struct ViewData {
    var voices: [Voice]
    var library: [LibraryItem]
    var recentReads: [ReadEntry]
    var dictations: [DictationEntry]
    var permissions: Permissions
    var voiceModel: ModelState
    var dictationModel: ModelState
    /// Optional downloads (Qwen3, word timing, Kokoro French) for the Models and Voices pages.
    var models: [ModelRow] = []
    var documentText: @MainActor (LibraryItem) throws -> String
    /// Snapshots only: the word shown highlighted in the reader when no live session is reading the document.
    var previewToken: Int?

    /// The first thing still missing, for the Home banner and the menu's "Finish setup…" row.
    var setupIssue: String? {
        if !permissions.accessibility { return "Allow Accessibility so Talk and Read can read selected text and highlight each word." }
        if !permissions.microphone { return "Allow the microphone so you can dictate." }
        switch dictationModel {
        case .missing, .failed: return "Download the dictation model to type with your voice."
        default: break
        }
        switch voiceModel {
        case .missing, .failed: return "Download the natural voice for the best reading quality."
        default: return nil
        }
    }
}

extension AppModel {
    var viewData: ViewData {
        ViewData(voices: voices, library: library, recentReads: recentReads, dictations: dictation.history, permissions: permissions,
                 voiceModel: voiceModel, dictationModel: dictationModel, models: models,
                 documentText: { [unowned self] in try self.documentText($0) })
    }
    var needsSetup: Bool { viewData.setupIssue != nil }
}

/// Which pane and document the main window shows; the menu bar, CLI `open` and Home's play button move it.
@MainActor final class WindowRouter: ObservableObject {
    static let shared = WindowRouter()

    enum Pane: String, CaseIterable, Identifiable {
        case home, library, dictation, voices, settings
        var id: Self { self }
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .home: "house"
            case .library: "books.vertical"
            case .dictation: "mic"
            case .voices: "waveform"
            case .settings: "gearshape"
            }
        }
    }

    @Published var pane: Pane = .home
    /// Library navigation stack; `[item]` shows that item in the reader.
    @Published var libraryPath: [LibraryItem] = []
    @Published var importError: String?
    /// Set by the app (lead): bring the main window forward, open onboarding.
    var showMainWindow: () -> Void = {}
    var openOnboarding: () -> Void = {}

    func open(_ item: LibraryItem) {
        pane = .library
        libraryPath = [item]
    }

    func show(_ pane: Pane) {
        self.pane = pane
        showMainWindow()
    }

    /// Imports dropped or chosen files; a single file opens in the reader.
    func importFiles(_ urls: [URL], into model: AppModel) {
        Task {
            var last: LibraryItem?
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do { last = try await model.importFile(url) } catch { importError = "\(url.lastPathComponent): \(error.localizedDescription)" }
            }
            if urls.count == 1, let last { open(last) } else { pane = .library }
        }
    }
}

/// The window's root view. The lead hosts this in the main window.
struct MainWindowView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var dictation: DictationController
    @ObservedObject private var router = WindowRouter.shared

    init(model: AppModel) {
        self.model = model
        _dictation = ObservedObject(wrappedValue: model.dictation)
    }

    var body: some View {
        let data = model.viewData
        MainWindowContent(model: model, data: data, router: router)
            // Keep permission ticks and the setup banner current while something is waiting on them.
            .task(id: router.pane == .settings || data.setupIssue != nil) {
                while !Task.isCancelled, router.pane == .settings || model.needsSetup {
                    model.refreshPermissions()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
    }
}

struct MainWindowContent: View {
    @ObservedObject var model: AppModel
    let data: ViewData
    @ObservedObject var router: WindowRouter

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { router.pane }, set: { if let p = $0 { router.pane = p } })) {
                ForEach(WindowRouter.Pane.allCases) { pane in
                    Label(pane.title, systemImage: pane.symbol).tag(pane)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            Group {
                switch router.pane {
                case .home: HomePane(model: model, data: data, router: router)
                case .library: LibraryPane(model: model, data: data, router: router)
                case .dictation: DictationPane(model: model, data: data)
                case .voices: VoicesPane(model: model, data: data)
                case .settings: SettingsContent(model: model, data: data).navigationTitle("Settings")
                }
            }
            .tint(Theme.accent)
        }
        .frame(minWidth: 760, idealWidth: 980, minHeight: 520, idealHeight: 680)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { Importer.kind(for: $0) != nil }
            guard !files.isEmpty else { return false }
            router.importFiles(files, into: model)
            return true
        }
        .alert("Couldn't open that", isPresented: Binding(get: { router.importError != nil }, set: { if !$0 { router.importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(router.importError ?? "")
        }
    }
}

// MARK: - Home

struct HomePane: View {
    @ObservedObject var model: AppModel
    let data: ViewData
    let router: WindowRouter
    @State private var text = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let issue = data.setupIssue { SetupBanner(text: issue) { router.openOnboarding() } }
                editor
                hint
                HStack(alignment: .top, spacing: 18) {
                    recentReads
                    recentDictations
                }
            }
            .padding(28)
            .frame(maxWidth: 880)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.surface)
        .navigationTitle("Home")
    }

    private var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var editor: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .font(.system(size: 16))
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 14).padding(.top, 14)
                .frame(minHeight: 180)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Paste or type text to listen to it")
                            .font(.system(size: 16)).foregroundStyle(.tertiary)
                            .padding(.leading, 19).padding(.top, 14)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Text to read aloud")
            HStack(spacing: 14) {
                let words = text.split(whereSeparator: \.isWhitespace).count
                Text(words == 1 ? "1 word" : "\(words) words").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if !text.isEmpty { Button("Clear") { text = "" }.buttonStyle(.borderless) }
                PlayButton(size: 40) { play() }
                    .disabled(isBlank)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Read aloud (⌘↩)")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .card(padding: 0)
    }

    private func play() {
        guard !isBlank else { return }
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Pasted text"
        let item = model.importText(text, title: String(firstLine.prefix(60)))
        model.read(item, fromToken: nil)
        router.open(item)
    }

    private var hint: some View {
        HStack(spacing: 14) {
            IconTile(symbol: "text.cursor", size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("Read anything on your Mac").font(.headline)
                Text("Select text in any app and press the shortcut. Press it again to stop.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            KeyCaps(display: model.settings.readShortcut.display)
        }
        .card()
    }

    private var recentReads: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent reads").font(.headline)
            VStack(spacing: 0) {
                if data.recentReads.isEmpty { EmptyNote(text: "Nothing read yet.") }
                let reads = Array(data.recentReads.prefix(6))
                ForEach(reads) { entry in
                    Button {
                        try? model.speak(entry.text, title: nil, caller: "user")
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(Self.preview(entry.text)).lineLimit(1)
                                Text(Self.caption(entry.app, entry.date)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "play.circle").font(.title3).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Read again: \(Self.preview(entry.text))")
                    if entry.id != reads.last?.id { Divider().padding(.leading, 14) }
                }
            }
            .card(padding: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var recentDictations: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent dictations").font(.headline)
            VStack(spacing: 0) {
                if data.dictations.isEmpty { EmptyNote(text: "Nothing dictated yet. \(holdHint(model.settings)).") }
                let entries = Array(data.dictations.prefix(6))
                ForEach(entries) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.text).lineLimit(2)
                            Text(Self.caption(entry.app, entry.date)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        CopyButton(text: entry.text)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    if entry.id != entries.last?.id { Divider().padding(.leading, 14) }
                }
            }
            .card(padding: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    static func preview(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map { String($0.prefix(140)) } ?? ""
    }

    static func caption(_ app: String?, _ date: Date) -> String {
        let when = date.formatted(.relative(presentation: .named))
        return app.map { "\($0) · \(when)" } ?? when
    }
}

/// "Hold the right Option key and speak", following the setting.
func holdHint(_ s: TalkReadCore.Settings) -> String {
    switch s.dictationHoldKey {
    case .rightOption: "Hold the right Option key and speak"
    case .fn: "Hold Fn and speak"
    case .rightCommand: "Hold the right Command key and speak"
    case .off: "Press \(s.dictationToggleShortcut.display) and speak"
    }
}

struct SetupBanner: View {
    let text: String
    let action: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.title3).symbolRenderingMode(.palette).foregroundStyle(Theme.onAccent, Theme.accent)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button("Finish setting up", action: action).buttonStyle(AccentButtonStyle())
        }
        .padding(14)
        .background(Theme.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent.opacity(0.55)))
        .accessibilityElement(children: .contain)
    }
}

struct EmptyNote: View {
    let text: String
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
    }
}

/// Copies on purpose (the user asked), so the pasteboard is not restored afterwards.
struct CopyButton: View {
    let text: String
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Copy")
        .accessibilityLabel("Copy")
    }
}

// MARK: - Library

struct LibraryPane: View {
    @ObservedObject var model: AppModel
    let data: ViewData
    @ObservedObject var router: WindowRouter
    @State private var choosingFiles = false
    @State private var askingAddress = false
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
                        Button("Open web page…", systemImage: "globe") { askingAddress = true }
                            .keyboardShortcut("l", modifiers: [.command, .shift])
                        Button("Open file…", systemImage: "plus") { choosingFiles = true }
                            .keyboardShortcut("o")
                    }
                }
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: Importer.contentTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { router.importFiles(urls, into: model) }
        }
        .sheet(isPresented: $askingAddress) { WebPageSheet(model: model, router: router) }
    }

    @ViewBuilder private var grid: some View {
        if data.library.isEmpty {
            ContentUnavailableView {
                Label("No documents yet", systemImage: "books.vertical")
            } description: {
                Text("Open a PDF, Word document, EPUB or web page, or drop files on this window.")
            } actions: {
                Button("Open file…") { choosingFiles = true }.buttonStyle(AccentButtonStyle())
                Button("Open web page…") { askingAddress = true }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surface)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 300), spacing: 16)], spacing: 16) {
                    ForEach(data.library) { item in
                        NavigationLink(value: item) { LibraryCard(item: item, progress: progress(item)) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Read") { model.read(item, fromToken: item.position); router.open(item) }
                                Button("Read from the start") { model.read(item, fromToken: 0); router.open(item) }
                                Divider()
                                Button("Remove from Library", role: .destructive) { model.remove(item) }
                            }
                    }
                }
                .padding(28)
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
            guard let text = try? data.documentText(item) else { continue }
            Self.tokenCounts[item.id] = await Task.detached { TextKit.tokenize(text).count }.value
            counts = Self.tokenCounts
        }
    }
}

struct LibraryCard: View {
    let item: LibraryItem
    let progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                IconTile(symbol: Theme.kindIcon(item.kind))
                Spacer()
                Text(Theme.kindName(item.kind)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            Text(item.title).font(.headline).lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 6) {
                ThinBar(value: progress ?? 0)
                HStack {
                    Text(item.added, format: .dateTime.day().month(.abbreviated))
                    Spacer()
                    Text(progressLabel)
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(16)
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

    private var url: URL? {
        let t = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let u = URL(string: t.contains("://") ? t : "https://" + t),
              ["http", "https"].contains(u.scheme?.lowercased() ?? ""), u.host != nil else { return nil }
        return u
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open a web page").font(.title3.weight(.semibold))
            Text("Talk and Read fetches the page once and keeps only its text on this Mac.").font(.callout).foregroundStyle(.secondary)
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
        .padding(22)
        .frame(width: 440)
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

// MARK: - Dictation

struct DictationPane: View {
    @ObservedObject var model: AppModel
    let data: ViewData
    @State private var query = ""
    @State var showVocabulary = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $showVocabulary) {
                Text("History").tag(false)
                Text("Vocabulary and clean-up").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 320).padding(.vertical, 14)
            if showVocabulary { vocabulary } else { history }
        }
        .background(Theme.surface)
        .navigationTitle("Dictation")
        .searchable(text: $query, prompt: "Search dictations")
    }

    private var filtered: [DictationEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? data.dictations : data.dictations.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    @ViewBuilder private var history: some View {
        if data.dictations.isEmpty {
            ContentUnavailableView("No dictations yet", systemImage: "mic",
                                   description: Text("\(holdHint(model.settings)), then let go. Your words are typed where the cursor is."))
        } else if filtered.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List(filtered) { entry in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.text).textSelection(.enabled)
                        Text(HomePane.caption(entry.app, entry.date)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button { model.insertAgain(entry.id) } label: { Image(systemName: "text.insert") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("Insert again where the cursor was").accessibilityLabel("Insert again")
                    CopyButton(text: entry.text)
                }
                .padding(.vertical, 6)
                .contextMenu {
                    Button("Insert Again") { model.insertAgain(entry.id) }
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.text, forType: .string) }
                    Divider()
                    Button("Delete", role: .destructive) { model.deleteDictation(entry.id) }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private var vocabulary: some View {
        Form {
            Section {
                Toggle("Remove filler words (um, uh, er)", isOn: $model.settings.removeFillers)
                Toggle("Polish with Apple Intelligence", isOn: $model.settings.polishWithAppleIntelligence)
            } header: {
                Text("Clean-up")
            } footer: {
                Text("Polish fixes punctuation and grammar on this Mac. It is off unless you turn it on.").foregroundStyle(.secondary)
            }
            Section {
                WordMapEditor(url: Paths.vocabulary, keyPrompt: "Heard as", valuePrompt: "Type instead")
            } header: {
                Text("Vocabulary")
            } footer: {
                Text("Names and terms the recogniser gets wrong, and what to type instead.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Voices

/// What every picker offers (V5, Junior 23 Oct): female voices of the models only, never system or male voices,
/// grouped by model (Kokoro, Qwen3, Breeze), American before British. The Voices page, Settings, the reader's and mini
/// player's menus and the menu bar share it.
enum VoiceGroups {
    static let models: [EngineKind] = [.neural, .qwen, .breeze]

    static func isBritish(_ v: Voice) -> Bool {
        let a = v.accent.lowercased()
        return a.contains("brit") || a.hasSuffix("gb") || a.contains("uk")
    }

    static func byModel(_ voices: [Voice], language: String) -> [(model: EngineKind, voices: [Voice])] {
        let female = voices.filter { $0.language == language && $0.gender.lowercased().hasPrefix("f") }
        return models.map { m in
            let own = female.filter { $0.engine == m }
            return (m, own.filter { !isBritish($0) } + own.filter(isBritish))
        }
        .filter { !$0.voices.isEmpty }
    }

    /// The voice a model starts on when it is picked (PLAN 0.3.0 decision 1): for Kokoro the Kokoro voice last chosen
    /// (`kokoro`: the fallback voice, or `ff_siwis`), otherwise the model's first voice.
    static func startVoice(_ voices: [Voice], kokoro: String) -> String? {
        (voices.first { $0.id == kokoro } ?? voices.first)?.id
    }

    static func name(_ id: String, in voices: [Voice]) -> String { voices.first { $0.id == id }?.name ?? id }

    /// A voice in a menu: "Emma (British)"; American voices by name alone.
    static func label(_ v: Voice) -> String { isBritish(v) ? "\(v.name) (British)" : v.name }

    /// Whether a download (`Engines.downloadables()`, by title) is needed by a model's voices in a language: the model
    /// itself and Parakeet v3 word timing for Qwen3 and Breeze, the French pack for Kokoro's French voice.
    // ponytail: matched by title because DownloadableModel names no engine; an `engine` property on it would end this.
    static func needs(_ model: EngineKind, language: String, title: String) -> Bool {
        let t = title.lowercased()
        switch model {
        case .qwen: return t.contains("qwen") || t.contains("parakeet")
        case .breeze: return t.contains("breeze") || t.contains("parakeet")
        case .neural: return language == "fr" && t.contains("french")
        case .system: return false
        }
    }

    /// Icon and one line for an optional download on the Models page.
    static func purpose(_ title: String) -> (symbol: String, what: String) {
        let t = title.lowercased()
        if t.contains("qwen") { return ("waveform", "More natural American and French voices") }
        if t.contains("breeze") { return ("waveform", "Expressive English voices") }
        if t.contains("parakeet") { return ("text.word.spacing", "Word timing for the Qwen3 voices") }
        if t.contains("french") { return ("globe.europe.africa", "Kokoro's French voice, Siwis") }
        return ("square.and.arrow.down", "Optional download")
    }

    static func blurb(_ model: EngineKind) -> String {
        switch model {
        case .neural: "Light and instant. The default."
        case .qwen: "More natural. Uses about 4 GB of memory while it reads; if it falls behind your speed, Kokoro reads the rest."
        case .breeze: "The most expressive. English only."
        case .system: ""
        }
    }
}

struct VoicesPane: View {
    @ObservedObject var model: AppModel
    let data: ViewData

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                speedCard
                VoicePickers(model: model, data: data)
            }
            .padding(28)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.surface)
        .navigationTitle("Voices")
    }

    private var speed: Double { Double(model.settings.speed) }

    private var speedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Reading speed").font(.headline)
                Spacer()
                Text(Theme.speed(speed)).font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
                    .accessibilityHidden(true)
            }
            HStack(spacing: 10) {
                Text("0.5×").font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(get: { speed }, set: { model.setSpeed(Float(($0 * 20).rounded() / 20)) }), in: 0.5...3.0)
                    .labelsHidden()
                    .accessibilityLabel("Reading speed")
                    .accessibilityValue(Theme.speed(speed))
                Text("3×").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach([1.0, 1.5, 2.0, 2.5], id: \.self) { p in
                    Button(Theme.speed(p)) { model.setSpeed(Float(p)) }.buttonStyle(ChipStyle(selected: abs(speed - p) < 0.001))
                }
                Spacer()
            }
        }
        .card()
    }
}

/// The English and the French voice, one section each (the Voices page and Settings ▸ Voices).
struct VoicePickers: View {
    @ObservedObject var model: AppModel
    let data: ViewData

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VoiceSection(model: model, data: data, language: "en")
            VoiceSection(model: model, data: data, language: "fr")
            Text("A new choice is used from the next read.").font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// One language's voice (V1, V2, V5): the model first, then that model's female voices. A model not yet downloaded
/// shows its size and a Download button; until it is ready another voice reads (`AppModel.voice(for:)`).
struct VoiceSection: View {
    @ObservedObject var model: AppModel
    let data: ViewData
    /// "en" or "fr".
    let language: String

    private var french: Bool { language == "fr" }
    private var current: String { french ? model.settings.frenchVoiceID : model.settings.voiceID }

    var body: some View {
        let groups = VoiceGroups.byModel(data.voices, language: language)
        let chosen = data.voices.first { $0.id == current }?.engine
        let shown = groups.first { $0.model == chosen } ?? groups.first
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(french ? "French voice" : "English voice").font(.headline)
                    Text(french ? "Reads text that is in French." : "Reads everything that is not French.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Picker("Model", selection: Binding(get: { chosen }, set: { m in pick(groups.first { $0.model == m }) })) {
                    ForEach(groups, id: \.model) { Text($0.model.modelName).tag(Optional($0.model)) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .accessibilityLabel("\(french ? "French" : "English") voice model")
            }
            if let shown {
                VStack(alignment: .leading, spacing: 0) {
                    Text(VoiceGroups.blurb(shown.model)).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
                    download(shown.model, shown.voices)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 4) {
                        ForEach(shown.voices) { v in
                            VoiceRow(voice: v, selected: v.id == current, choose: { model.setVoice(v.id) }, preview: { preview(v) })
                        }
                    }
                    .padding(8)
                }
                .card(padding: 0)
            } else {
                EmptyNote(text: data.voices.isEmpty ? "Loading voices…" : "No \(french ? "French" : "English") voices yet.").card(padding: 0)
            }
        }
    }

    /// The model's missing downloads as one row: Kokoro's English voice is the existing voice download; the others come
    /// from `Engines.downloadables()`.
    @ViewBuilder private func download(_ kind: EngineKind, _ voices: [Voice]) -> some View {
        if voices.contains(where: { !$0.installed }) {
            if kind == .neural && !french {
                ModelStatusRow(kind: .voice, state: data.voiceModel) { model.downloadModels() }
            } else {
                let matched = data.models.filter { VoiceGroups.needs(kind, language: language, title: $0.title) }
                let rows = matched.isEmpty ? data.models.filter { $0.state != .ready } : matched
                let state = ModelStatusRow.combined(rows)
                ModelStatusRow(symbol: "square.and.arrow.down", title: "\(kind.modelName) needs a download",
                               what: "Another voice reads until it is ready", megabytes: ModelStatusRow.megabytes(rows), state: state) {
                    for r in rows where r.state != .ready { model.download(r.title) }
                }
            }
            Divider().padding(.horizontal, 14)
        }
    }

    private func pick(_ group: (model: EngineKind, voices: [Voice])?) {
        guard let group, let id = VoiceGroups.startVoice(group.voices, kokoro: french ? "ff_siwis" : model.settings.fallbackVoiceID) else { return }
        model.setVoice(id)
    }

    /// Plays a short sample in that voice without choosing it.
    private func preview(_ v: Voice) {
        let text = v.language == "fr" ? "Bonjour, je suis \(v.name). Voici comment je lis vos textes."
            : "Hello, I'm \(v.name). This is how I sound reading your text."
        try? model.speak(text, title: nil, caller: "ui-preview", voice: v.id)
    }
}

struct VoiceRow: View {
    let voice: Voice
    let selected: Bool
    let choose: () -> Void
    let preview: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if selected { Tick(size: 20) } else { Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1.5).frame(width: 18, height: 18) }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(voice.name).fontWeight(selected ? .semibold : .regular).lineLimit(1)
                Text(voice.accent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(action: preview) { Image(systemName: "play.circle").font(.title3) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(!voice.installed)
                .opacity(voice.installed ? 1 : 0.35)
                .help(voice.installed ? "Play a sample" : "Download it to hear a sample")
                .accessibilityLabel("Preview \(voice.name)")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(selected ? Theme.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: choose)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(voice.name), \(voice.accent)\(selected ? ", current voice" : "")")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Choose", choose)
    }
}
