// Settings: General, Shortcuts, Highlight, Dictation, Pronunciations, Permissions, Models, About. Used by the Settings
// window (⌘,) and the main window's Settings pane. Owned by WP6.
import AppKit
import SwiftUI
import TalkReadCore

/// Root for the Settings window. Keeps permission ticks current while it is open.
struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsContent(model: model, data: model.viewData)
            .frame(minWidth: 720, minHeight: 500)
            .task {
                while !Task.isCancelled {
                    model.refreshPermissions()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
    }
}

struct SettingsContent: View {
    enum Tab: String, CaseIterable {
        case general, shortcuts, highlight, dictation, pronunciations, permissions, models, about
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .shortcuts: "keyboard"
            case .highlight: "highlighter"
            case .dictation: "mic"
            case .pronunciations: "character.bubble"
            case .permissions: "lock.shield"
            case .models: "square.and.arrow.down"
            case .about: "info.circle"
            }
        }
    }

    @ObservedObject var model: AppModel
    let data: ViewData
    @State var tab: Tab = .general

    /// A category column rather than a TabView: eight toolbar tabs overflow on macOS 26 and fight the main window's toolbar.
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Tab.allCases, id: \.self) { t in
                    Button { tab = t } label: {
                        HStack(spacing: 8) {
                            Image(systemName: t.symbol).frame(width: 22).foregroundStyle(.secondary)
                            Text(t.title)
                        }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(tab == t ? Theme.accent.opacity(0.24) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == t ? [.isSelected] : [])
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 190)
            Divider()
            page.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .tint(Theme.accent)
    }

    @ViewBuilder private var page: some View {
        switch tab {
        case .general: general
        case .shortcuts: ShortcutsPage(model: model)
        case .highlight: highlight
        case .dictation: dictation
        case .pronunciations: pronunciations
        case .permissions: permissions
        case .models: models
        case .about: about
        }
    }

    // MARK: General

    private var general: some View {
        Form {
            Section {
                Toggle("Open Talk and Read at login", isOn: $model.settings.launchAtLogin)
            }
            Section("Mini player") {
                Toggle("Show the mini player when reading", isOn: $model.settings.showMiniPlayer)
                Picker("Hide it after reading ends", selection: Binding(get: { Int(model.settings.miniPlayerAutoHideSeconds) },
                                                                        set: { model.settings.miniPlayerAutoHideSeconds = Double($0) })) {
                    Text("Never").tag(0)
                    ForEach([3, 5, 10, 30], id: \.self) { Text("\($0) seconds").tag($0) }
                }
                Toggle("Show three lines of subtitles", isOn: $model.settings.subtitlesExpanded)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Highlight

    private var highlightColour: Binding<Color> {
        Binding(get: { Color(nsColor: NSColor(hex: model.settings.highlightHex) ?? Theme.accentNS) },
                set: { model.settings.highlightHex = NSColor($0).hexString })
    }

    private var highlight: some View {
        Form {
            Section {
                HighlightPreview(colour: NSColor(hex: model.settings.highlightHex) ?? Theme.accentNS, tint: model.settings.tintEnabled)
                ColorPicker("Word colour", selection: highlightColour, supportsOpacity: false)
                Toggle("Tint the sentence being read", isOn: $model.settings.tintEnabled)
                LabeledContent("Box opacity") {
                    Slider(value: $model.settings.opacity, in: 0.1...1).frame(width: 220).accessibilityValue("\(Int(model.settings.opacity * 100)) percent")
                }
                if model.settings.highlightHex.uppercased() != Theme.accentHex {
                    Button("Use the Talk and Read yellow") { model.settings.highlightHex = Theme.accentHex }
                }
            }
            Section {
                Toggle("Use screen text recognition when an app hides its text", isOn: $model.settings.useOCRFallback)
            } footer: {
                Text("Needs Screen Recording. Talk and Read looks only at the window it is reading, on this Mac.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Dictation

    private var dictation: some View {
        Form {
            Section {
                Toggle("Remove filler words (um, uh, er)", isOn: $model.settings.removeFillers)
                Toggle("Polish with Apple Intelligence", isOn: $model.settings.polishWithAppleIntelligence)
            } footer: {
                Text("Polish fixes punctuation and grammar on this Mac. Custom words live in the Dictation section of the main window.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Pronunciations

    private var pronunciations: some View {
        Form {
            Section {
                WordMapEditor(url: Paths.pronunciations, keyPrompt: "Word", valuePrompt: "Say it as")
            } footer: {
                Text("For names and words the voice gets wrong, for example Nguyen → win. The word on screen stays as written.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Permissions

    private var permissions: some View {
        Form {
            Section {
                PermissionRow(symbol: "accessibility", title: "Accessibility", detail: "Reads selected text, highlights words and types dictation.",
                              granted: data.permissions.accessibility, buttonTitle: "Open System Settings") { model.request(.accessibility) }
                PermissionRow(symbol: "mic", title: "Microphone", detail: "Dictation. Audio never leaves this Mac.",
                              granted: data.permissions.microphone, buttonTitle: "Open System Settings") { model.request(.microphone) }
                PermissionRow(symbol: "rectangle.dashed.badge.record", title: "Screen Recording (optional)",
                              detail: "Only for apps that hide their text from Accessibility.",
                              granted: data.permissions.screenRecording, buttonTitle: "Open System Settings") { model.request(.screenRecording) }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Models

    private var models: some View {
        Form {
            Section {
                ModelStatusRow(kind: .voice, state: data.voiceModel) { model.downloadModels() }
                ModelStatusRow(kind: .dictation, state: data.dictationModel) { model.downloadModels() }
            } footer: {
                Text("Downloaded once from Hugging Face, then everything runs offline on this Mac.").foregroundStyle(.secondary)
            }
            Section {
                Picker("Free memory when unused for", selection: $model.settings.unloadAfterMinutes) {
                    ForEach([5, 10, 20, 30, 60], id: \.self) { Text("\($0) minutes").tag($0) }
                }
            } footer: {
                Text("The models load again in a moment the next time you read or dictate.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: About

    private var about: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96).accessibilityHidden(true)
            Text("Talk and Read").font(.title2.weight(.semibold))
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")")
                .foregroundStyle(.secondary).textSelection(.enabled)
            Text("Reads and types for you, entirely on this Mac. No account, no analytics, and nothing you read or say leaves this computer.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shortcuts (S2): a Dictation and a Text to Speech card, one row per action (title, one-line description, key caps you
/// click to record a new combination), then Reset shortcuts. Changes apply at once through the settings watcher, which
/// reloads the hotkeys. Says so when Speechify is open, since it answers the same default keys (S5).
struct ShortcutsPage: View {
    @ObservedObject var model: AppModel
    /// Checked each time the page appears, never polled; the snapshot self-test passes `{ true }`.
    var speechifyRunning: () -> Bool = {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.cliffweitzman.speechifymacagent").isEmpty
    }
    @State private var speechifyOpen = false

    static let rows: [String: (title: String, detail: String)] = [
        "dictationToggleShortcut": ("Hands-free dictation", "Tap once to start, tap again to stop and type"),
        "pasteLastShortcut": ("Paste last transcript", "Types your latest dictation again"),
        "readShortcut": ("Start reading", "Reads the selected text; press again to stop"),
        "pauseShortcut": ("Pause or resume", "Holds or carries on with the current read"),
        "screenshotShortcut": ("Screenshot and listen", "Drag over part of the screen to hear its text"),
        "increaseSpeedShortcut": ("Increase speed", "0.05× faster, while something is being read"),
        "decreaseSpeedShortcut": ("Decrease speed", "0.05× slower, while something is being read"),
        "skipBackwardShortcut": ("Skip backward", "Back one sentence in the current read"),
        "skipForwardShortcut": ("Skip forward", "On one sentence in the current read"),
    ]
    private static let dictationKeys = ["dictationToggleShortcut", "pasteLastShortcut"]
    private static let readingKeys = TalkReadCore.Settings.chords.map(\.key).filter { !dictationKeys.contains($0) }

    /// The inline message for a refused combination.
    static func message(_ refusal: TalkReadCore.Settings.Refusal, _ s: TalkReadCore.Settings.Shortcut) -> String {
        switch refusal {
        case .needsModifier: "\(s.display) on its own would stop that key typing. Add ⌃, ⌥ or ⌘."
        case .reserved: "\(s.display) belongs to macOS. Try another."
        case .taken(let other): "\(s.display) is already used by \(rows[other]?.title ?? other). Try another."
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shortcuts").font(.title2.weight(.bold))
                    Text("Keys that work in every app. Click a shortcut to change it.").foregroundStyle(.secondary)
                }
                if speechifyOpen { speechifyNotice }
                section("Dictation") {
                    row("Start dictation", "Hold the key on its own, speak, then let go") {
                        Picker("Hold to dictate", selection: $model.settings.dictationHoldKey) {
                            Text("Hold right Option").tag(TalkReadCore.Settings.HoldKey.rightOption)
                            Text("Hold Fn").tag(TalkReadCore.Settings.HoldKey.fn)
                            Text("Hold right Command").tag(TalkReadCore.Settings.HoldKey.rightCommand)
                            Text("Off").tag(TalkReadCore.Settings.HoldKey.off)
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                    }
                    ForEach(Self.dictationKeys, id: \.self) { key in
                        Divider()
                        recorderRow(key)
                    }
                    Divider()
                    row("Cancel dictation", "Stops recording; nothing is typed") { KeyCaps(display: "esc") }
                }
                section("Text to Speech") {
                    ForEach(Array(Self.readingKeys.enumerated()), id: \.element) { i, key in
                        if i > 0 { Divider() }
                        recorderRow(key)
                    }
                }
                row("Reset shortcuts", "Puts every key back to how it started") {
                    Button("Reset") { model.settings.resetShortcuts() }
                }
                .card(padding: 0)
                .padding(.top, 14)
            }
            .frame(maxWidth: 620)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .onAppear { speechifyOpen = speechifyRunning() }
    }

    private var speechifyNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Speechify is open").font(.body.weight(.semibold))
                Text("It answers the same keys as the defaults here, so one press can reach both apps. Quit Speechify, or give Talk and Read different keys below.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .card(padding: 14)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.accent.opacity(0.6)))
        .accessibilityElement(children: .combine)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).padding(.leading, 4).padding(.top, 12)
            VStack(spacing: 0) { content() }.card(padding: 0)
        }
    }

    private func row<Trailing: View>(_ title: String, _ detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .accessibilityElement(children: .contain)
    }

    private func recorderRow(_ key: String) -> some View {
        let path = TalkReadCore.Settings.chords.first { $0.key == key }!.path
        let text = Self.rows[key] ?? (key, "")
        return row(text.title, text.detail) {
            ShortcutRecorder(key: key, shortcut: Binding(get: { model.settings[keyPath: path] }, set: { model.settings[keyPath: path] = $0 })) { s in
                model.settings.refusal(s, for: key).map { Self.message($0, s) }
            }
        }
    }
}

/// A sample line showing the word box and sentence tint in the chosen colour.
private struct HighlightPreview: View {
    let colour: NSColor
    let tint: Bool
    var body: some View {
        HStack(spacing: 0) {
            Text("The ferry leaves at ")
            Text("half").foregroundStyle(Theme.onAccent).padding(.horizontal, 3)
                .background(Color(nsColor: colour), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(" past six.")
        }
        .font(.system(size: 17))
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(tint ? Color(nsColor: colour).opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .accessibilityLabel("Highlight preview")
    }
}

/// Term → replacement rows saved as a `[String: String]` JSON file (vocabulary.json, pronunciations.json).
struct WordMapEditor: View {
    struct Row: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var value: String
    }

    let url: URL
    let keyPrompt: String
    let valuePrompt: String
    @State private var rows: [Row]

    init(url: URL, keyPrompt: String, valuePrompt: String) {
        self.url = url
        self.keyPrompt = keyPrompt
        self.valuePrompt = valuePrompt
        _rows = State(initialValue: Self.load(url).sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { Row(key: $0.key, value: $0.value) })
    }

    var body: some View {
        ForEach($rows) { $row in
            HStack(spacing: 10) {
                TextField(keyPrompt, text: $row.key, prompt: Text(keyPrompt)).labelsHidden()
                Image(systemName: "arrow.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                TextField(valuePrompt, text: $row.value, prompt: Text(valuePrompt)).labelsHidden()
                Button { rows.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(row.key)")
            }
        }
        Button { rows.append(Row(key: "", value: "")) } label: { Label("Add", systemImage: "plus") }
            .buttonStyle(.borderless)
            .onChange(of: rows) { _, rows in Self.save(rows, to: url) }
    }

    static func load(_ url: URL) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
    }

    static func save(_ rows: [Row], to url: URL) {
        let pairs = rows.compactMap { r -> (String, String)? in
            let k = r.key.trimmingCharacters(in: .whitespaces)
            return k.isEmpty ? nil : (k, r.value.trimmingCharacters(in: .whitespaces))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(Dictionary(pairs, uniquingKeysWith: { _, last in last })).write(to: url, options: .atomic)
    }
}
