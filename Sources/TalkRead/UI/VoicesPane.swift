import AppKit
import SwiftUI
import TalkReadCore

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
        if t.contains("breeze") { return ("waveform", "Expressive English voices") }   // its licence row follows it
        if t.contains("parakeet") { return ("text.word.spacing", "Dictation in French and other languages, and word timing for the Qwen3 and Breeze voices") }
        if t.contains("french") { return ("globe.europe.africa", "Kokoro's French voice, Siwis") }
        return ("square.and.arrow.down", "Optional download")
    }

    static func blurb(_ model: EngineKind) -> String {
        switch model {
        case .neural: "Light and instant. The default."
        case .qwen: "More natural. Uses about 4 GB of memory while it reads; if it falls behind your speed, Kokoro reads the rest."
        // Peak memory while it reads, 6.0-6.7 GB over the 0.4.0 sustained runs (5.5 GB once loaded).
        case .breeze: "The most expressive. English only. Uses about 7 GB of memory while it reads; above about \(String(format: "%g", BreezeEngine.keepsUpTo))× Kokoro reads the rest."
        case .system: ""
        }
    }
}

struct VoicesPane: View {
    @ObservedObject var model: AppModel
    let data: ViewData

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.spacious) {
                speedCard
                VoicePickers(model: model, data: data)
            }
            .padding(Space.spacious)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.surface)
        .navigationTitle("Voices")
    }

    private var speed: Double { Double(model.activeSpeed) }   // a preview shows its own speed

    private var speedCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Reading speed").font(.headline)
                Spacer()
                Text(Theme.speed(speed)).font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
                    .accessibilityHidden(true)
            }
            HStack(spacing: Space.md) {
                Text("0.5×").font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(get: { speed }, set: { model.setSpeed(Float(($0 * 4).rounded() / 4)) }), in: SpeedPanel.range, step: 0.25)
                    .labelsHidden()
                    .accessibilityLabel("Reading speed")
                    .accessibilityValue(Theme.speed(speed))
                Text("4×").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: Space.sm) {
                ForEach(Theme.speedPresets, id: \.self) { p in
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
        VStack(alignment: .leading, spacing: Space.spacious) {
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
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.md) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(french ? "French voice" : "English voice").font(.headline)
                    Text(french ? "Reads text that is in French." : "Reads everything that is not French.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: Space.md)
                Picker("Model", selection: Binding(get: { chosen }, set: { m in pick(groups.first { $0.model == m }) })) {
                    ForEach(groups, id: \.model) { Text($0.model.modelName).tag(Optional($0.model)) }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
                .accessibilityLabel("\(french ? "French" : "English") voice model")
            }
            if let shown {
                VStack(alignment: .leading, spacing: 0) {
                    Text(VoiceGroups.blurb(shown.model)).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Space.lg).padding(.top, Space.md).padding(.bottom, Space.sm)
                    // Beside the download that is the consent, and whenever Breeze is shown (PLAN 0.4.0 Sol rev. 6, V8).
                    if shown.model == .breeze { BreezeLicence().padding(.horizontal, Space.lg).padding(.bottom, Space.sm) }
                    download(shown.model, shown.voices)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.sm), GridItem(.flexible(), spacing: Space.sm)], spacing: Space.xs) {
                        ForEach(shown.voices) { v in
                            VoiceRow(voice: v, selected: v.id == current, choose: { model.setVoice(v.id) }, preview: { model.preview(v) })
                        }
                    }
                    .padding(Space.sm)
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
            Divider().padding(.horizontal, Space.lg)
        }
    }

    private func pick(_ group: (model: EngineKind, voices: [Voice])?) {
        guard let group, let id = VoiceGroups.startVoice(group.voices, kokoro: french ? "ff_siwis" : model.settings.fallbackVoiceID) else { return }
        model.setVoice(id)
    }

}

/// Breeze TTS 2's weights are under BreezeBlue's research and non-commercial licence (PLAN 0.4.0 Sol rev. 6, V8): the
/// note, and the full pinned `LICENSE` (bundled as text, never the weights) in a sheet. Shown with Breeze on the Voices
/// page, next to its download, and on Settings ▸ Models.
struct BreezeLicence: View {
    static let note = "Personal, non-commercial use only (Breeze licence)."
    @State private var showing = false

    var body: some View {
        HStack(spacing: Space.sm) {
            Text(Self.note).font(.callout).foregroundStyle(.secondary)
            Button("Read the licence") { showing = true }.buttonStyle(.link)
        }
        .sheet(isPresented: $showing) {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Breeze TTS 2 licence").font(.headline)
                Text("The Breeze voices may be used for personal, non-commercial purposes only. The full licence:")
                    .font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    Text(Self.text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack { Spacer(); Button("Done") { showing = false }.keyboardShortcut(.defaultAction) }
            }
            .padding(Space.xl)
            .frame(width: 640, height: 520)
        }
    }

    /// The licence at the pinned model revision, from the app bundle; in a `swift build` run the source tree's copy.
    static var text: String {
        let url = Bundle.main.url(forResource: "Breeze-TTS-2-LICENSE", withExtension: "txt", subdirectory: "Licences")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../Resources/Licences/Breeze-TTS-2-LICENSE.txt").standardized
        return (try? String(contentsOf: url, encoding: .utf8)) ?? "The licence text is missing from this copy of Talk & Read; it is the LICENSE file beside the Breeze model."
    }
}

struct VoiceRow: View {
    let voice: Voice
    let selected: Bool
    let choose: () -> Void
    let preview: () -> Void

    var body: some View {
        HStack(spacing: Space.md) {
            Group {
                if selected { Tick(size: 20) } else { Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1.5).frame(width: 18, height: 18) }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(voice.name).fontWeight(selected ? .semibold : .regular).lineLimit(1)
                Text(voice.accent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Space.xs)
            Button(action: preview) { Image(systemName: "play.circle").font(.title3) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(!voice.installed)
                .opacity(voice.installed ? 1 : 0.35)
                .help(voice.installed ? "Play a sample" : "Download it to hear a sample")
                .accessibilityLabel("Preview \(voice.name)")
        }
        .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
        .background(selected ? Theme.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: choose)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(voice.name), \(voice.accent)\(selected ? ", current voice" : "")")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Choose", choose)
    }
}
