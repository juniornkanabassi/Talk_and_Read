// Main window: sidebar (Home, Library, Dictation) and its panes. Owned by WP6.
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
    /// Optional downloads (Qwen3, Breeze, word timing, Kokoro French) for the Models and Voices pages.
    var models: [ModelRow] = []
    var documentText: @MainActor (LibraryItem) throws -> String
    /// Snapshots only: the word shown highlighted in the reader when no live session is reading the document.
    var previewToken: Int?

    /// The first thing still missing, for the Home banner and the menu's "Finish setup…" row.
    var setupIssue: String? {
        if !permissions.accessibility { return "Allow Accessibility so Talk & Read can read selected text and highlight each word." }
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
    @Published var settingsTab: SettingsContent.Tab = .general {
        didSet {
            if ProcessInfo.processInfo.environment["TALKREAD_HOME"] == nil {
                UserDefaults.standard.set(settingsTab.rawValue, forKey: "settingsCategory")
            }
        }
    }

    init() {
        if ProcessInfo.processInfo.environment["TALKREAD_HOME"] == nil,
           let name = UserDefaults.standard.string(forKey: "settingsCategory"),
           let saved = SettingsContent.Tab(rawValue: name) { settingsTab = saved }
    }
    /// Library navigation stack; `[item]` shows that item in the reader.
    @Published var libraryPath: [LibraryItem] = []
    @Published var importError: String?
    @Published var choosingFiles = false
    @Published var askingAddress = false
    @Published var sidebarVisibility: NavigationSplitViewVisibility = .all
    /// Set by the app (lead): bring the main window forward, open onboarding.
    var showMainWindow: () -> Void = {}
    var openOnboarding: () -> Void = {}
    var openSettings: (SettingsContent.Tab) -> Void = { _ in }

    func open(_ item: LibraryItem) {
        pane = .library
        libraryPath = [item]
    }

    func show(_ pane: Pane) {
        if pane == .settings || pane == .voices {
            openSettings(pane == .voices ? .voices : .general)
        } else {
            self.pane = pane
            showMainWindow()
        }
    }

    func chooseFiles(into model: AppModel) {
        pane = .library
        showMainWindow()
        choosingFiles = true
    }

    func openWebPage() {
        pane = .library
        showMainWindow()
        askingAddress = true
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
        // Permission ticks and the setup banner stay current through AppDelegate's 2 s poll while a window is open.
        MainWindowContent(model: model, data: data, router: router)
    }
}

struct MainWindowContent: View {
    @ObservedObject var model: AppModel
    let data: ViewData
    @ObservedObject var router: WindowRouter

    var body: some View {
        NavigationSplitView(columnVisibility: $router.sidebarVisibility) {
            List(selection: Binding(get: { router.pane }, set: { if let p = $0 { router.pane = p } })) {
                ForEach([WindowRouter.Pane.home, .library, .dictation]) { pane in
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
                case .voices, .settings: HomePane(model: model, data: data, router: router)
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
        .onChange(of: router.pane) { _, pane in
            if pane == .voices || pane == .settings {
                router.openSettings(pane == .voices ? .voices : .general)
                router.pane = .home
            }
        }
        .alert("Unable to open file", isPresented: Binding(get: { router.importError != nil }, set: { if !$0 { router.importError = nil } })) {
            Button("Close", role: .cancel) {}
        } message: {
            Text(router.importError ?? "")
        }
    }
}
