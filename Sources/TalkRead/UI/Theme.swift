// One accent (the icon's yellow), charcoal/off-white surfaces, and the few shared pieces every screen uses. Owned by WP6.
import AppKit
import SwiftUI
import TalkReadCore

enum Theme {
    static let accentHex = "#FFD21F"
    static let accentNS = NSColor(hex: accentHex)!
    static let onAccentNS = NSColor(hex: "#1A1A1A")!
    static let accent = Color(nsColor: accentNS)
    /// Text and glyphs on yellow.
    static let onAccent = Color(nsColor: onAccentNS)
    static let surface = Color(nsColor: .dynamic(light: "#F7F7F4", dark: "#16181D"))
    static let card = Color(nsColor: .dynamic(light: "#FFFFFF", dark: "#1F2229"))
    static let readingWidth: CGFloat = 680
    /// The speed panel's chips, the menu bar's Speed menu and the Voices page.
    static let speedPresets: [Double] = TalkReadCore.Settings.speedPresets.map(Double.init)
    // ponytail: words a minute at 1x, Kokoro af_heart on the selftest-tts fixture; the panel's "about N words a minute".
    // Re-measure if the default voice changes.
    static let wordsPerMinuteAt1x = 155.0
    /// Rounded to 5, as the panel shows it.
    static func wordsPerMinute(_ speed: Double) -> Int { Int((wordsPerMinuteAt1x * speed / 5).rounded()) * 5 }

    static func speed(_ s: Double) -> String { String(format: "%.2f×", s) }

    /// "90 MB", "3.1 GB".
    static func size(_ megabytes: Int) -> String {
        megabytes < 1000 ? "\(megabytes) MB" : String(format: "%.1f GB", Double(megabytes) / 1000)
    }

    static func kindIcon(_ kind: String) -> String {
        switch kind {
        case "pdf": "doc.richtext"
        case "epub": "book.closed"
        case "web": "globe"
        case "docx", "rtf": "doc.text"
        case "html": "chevron.left.forwardslash.chevron.right"
        case "markdown": "number"
        case "pasted": "doc.on.clipboard"
        default: "doc.plaintext"
        }
    }

    static func kindName(_ kind: String) -> String {
        switch kind {
        case "pdf": "PDF"
        case "epub": "EPUB"
        case "web": "Web page"
        case "docx": "Word"
        case "rtf": "Rich text"
        case "html": "HTML"
        case "markdown": "Markdown"
        case "pasted": "Pasted"
        default: "Text"
        }
    }
}

extension NSColor {
    /// "#RRGGBB" in sRGB.
    convenience init?(hex: String) {
        let s = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return Theme.accentHex }
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    static func dynamic(light: String, dark: String) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark)! : NSColor(hex: light)! }
    }
}

extension EnvironmentValues {
    /// True while views are rendered offscreen for `--selftest-ui-snapshots`: Liquid Glass is composited by the window
    /// server and does not appear in offscreen renders, so surfaces fall back to a material there.
    @Entry var offscreenRender = false
}

extension View {
    /// Rounded card on the window surface.
    func card(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }

    /// Floating controls (reader transport, mini player): Liquid Glass live, material offscreen.
    func panelSurface<S: InsettableShape>(_ shape: S) -> some View { modifier(PanelSurface(shape: shape)) }
}

private struct PanelSurface<S: InsettableShape>: ViewModifier {
    @Environment(\.offscreenRender) private var offscreen
    let shape: S
    func body(content: Content) -> some View {
        if offscreen {
            content.background(.regularMaterial, in: shape).overlay(shape.strokeBorder(Color.primary.opacity(0.1)))
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}

/// The yellow circular play/pause button (the app's primary action).
struct PlayButton: View {
    var playing = false
    var size: CGFloat = 44
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(Theme.onAccent)
                .offset(x: playing ? 0 : size * 0.03)
                .frame(width: size, height: size)
                .background(Theme.accent, in: Circle())
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playing ? "Pause" : "Play")
        .help(playing ? "Pause" : "Play")
    }
}

/// Small borderless symbol button used in transport rows.
struct SymbolButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 15
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size * 2.1, height: size * 2.1)
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// Yellow capsule button with near-black text, for the one primary action on a screen.
struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
            .opacity(enabled ? 1 : 0.45)
    }
}

/// Capsule choice chip; selected = yellow.
struct ChipStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium).monospacedDigit())
            .foregroundStyle(selected ? Theme.onAccent : .primary)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07)), in: Capsule())
    }
}

/// Thin yellow progress bar (AppKit's indicator ignores the accent).
struct ThinBar: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(Theme.accent).frame(width: max(0, min(1, value)) * g.size.width)
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

/// "⌃⌥R" as key caps.
struct KeyCaps: View {
    let display: String
    var body: some View {
        let mods = display.prefix { "⌃⌥⇧⌘".contains($0) }
        let caps = mods.map(String.init) + [String(display.dropFirst(mods.count))].filter { !$0.isEmpty }
        HStack(spacing: 3) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                Text(cap)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .frame(minWidth: 20, minHeight: 20)
                    .padding(.horizontal, cap.count > 1 ? 5 : 0)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            }
        }
        .accessibilityElement()
        .accessibilityLabel(display.isEmpty ? "No shortcut" : display)
    }
}

/// Yellow-filled tick for "granted" / "ready" / "current".
struct Tick: View {
    var size: CGFloat = 17
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: size))
            .symbolRenderingMode(.palette)
            .foregroundStyle(Theme.onAccent, Theme.accent)
    }
}

/// Icon in a soft yellow tile.
struct IconTile: View {
    let symbol: String
    var size: CGFloat = 36
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .medium))
            .frame(width: size, height: size)
            .background(Theme.accent.opacity(0.2), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// One permission with its live status and the button that asks for it.
struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let granted: Bool
    var buttonTitle = "Allow…"
    let request: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if granted {
                Label { Text("Allowed") } icon: { Tick() }.font(.callout).foregroundStyle(.secondary)
            } else {
                Button(buttonTitle, action: request)
            }
        }
        .padding(14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(granted ? "allowed" : "not allowed")")
    }
}

/// A downloadable model: size, progress, ready or failed.
struct ModelStatusRow: View {
    enum Kind { case voice, dictation }
    let symbol: String
    let title: String
    let what: String
    let megabytes: Int
    let state: ModelState
    /// nil hides the row's own button (onboarding has one button for both).
    var download: (() -> Void)?

    init(symbol: String, title: String, what: String, megabytes: Int, state: ModelState, download: (() -> Void)? = nil) {
        (self.symbol, self.title, self.what, self.megabytes, self.state, self.download) = (symbol, title, what, megabytes, state, download)
    }

    /// Kokoro's English voice and the dictation model.
    init(kind: Kind, state: ModelState, download: (() -> Void)? = nil) {
        self.init(symbol: kind == .voice ? "waveform" : "mic", title: kind == .voice ? "Natural voice" : "Dictation model",
                  what: kind == .voice ? "Kokoro, American and British voices" : "Parakeet, fast and accurate English",
                  megabytes: Self.megabytes(kind, state), state: state, download: download)
    }

    /// One optional download (Models page).
    init(row: ModelRow, download: (() -> Void)? = nil) {
        let p = VoiceGroups.purpose(row.title)
        self.init(symbol: p.symbol, title: row.title, what: p.what, megabytes: row.megabytes, state: row.state, download: download)
    }

    static func megabytes(_ kind: Kind, _ state: ModelState) -> Int {
        if case .missing(let mb) = state, mb > 0 { return mb }
        return kind == .voice ? AppModel.voiceMegabytes : AppModel.dictationMegabytes
    }

    /// What is left to fetch of several downloads (what was already fetched is not counted again).
    static func megabytes(_ rows: [ModelRow]) -> Int {
        let left = rows.filter { $0.state != .ready }
        return (left.isEmpty ? rows : left).reduce(0) { $0 + $1.megabytes }
    }

    /// One state for several downloads a model needs: failed if any failed, ready when all are, downloading with
    /// size-weighted progress while any is, else missing.
    static func combined(_ rows: [ModelRow]) -> ModelState {
        for r in rows { if case .failed = r.state { return r.state } }
        if rows.allSatisfy({ $0.state == .ready }) { return .ready }
        guard rows.contains(where: { if case .downloading = $0.state { true } else { false } }) else {
            return .missing(megabytes: megabytes(rows))
        }
        let total = Double(rows.reduce(0) { $0 + $1.megabytes })
        let done = rows.reduce(0.0) { sum, r in
            if r.state == .ready { return sum + Double(r.megabytes) }
            if case .downloading(let p) = r.state { return sum + p * Double(r.megabytes) }
            return sum
        }
        return .downloading(progress: total > 0 ? done / total : 0)
    }

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: symbol)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if case .downloading(let p) = state { ThinBar(value: p).frame(maxWidth: 240).padding(.top, 2) }
            }
            Spacer(minLength: 12)
            switch state {
            case .ready:
                Label { Text("Ready") } icon: { Tick() }.font(.callout).foregroundStyle(.secondary)
            case .downloading(let p):
                Text("\(Int((p * 100).rounded())) %").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            case .missing:
                if let download { Button("Download", action: download) }
            case .failed:
                if let download { Button("Try again", action: download) }
            }
        }
        .padding(14)
        .accessibilityElement(children: .contain)
    }

    private var detail: String {
        let size = Theme.size(megabytes)
        switch state {
        case .ready: return what
        case .downloading: return "\(what) · downloading \(size)"
        case .missing: return "\(what) · \(size) download"
        case .failed(let why): return "Download failed: \(why)"
        }
    }
}
