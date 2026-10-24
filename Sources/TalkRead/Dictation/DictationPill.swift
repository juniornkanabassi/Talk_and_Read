// Non-activating pill near the bottom centre of the screen with the pointer: live text on top, level meter underneath,
// cancel at the top right. Never key or main; Esc cancels through the hotkey tap, not here.
import AppKit
import SwiftUI
import TalkReadCore

@MainActor final class DictationPill {
    static let width: CGFloat = 460
    private let panel: NSPanel

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    init(dictation: DictationController) {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 72), styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // ponytail: the whole panel takes clicks (only the ✕ acts on them); per-region pass-through needs a
        // mouse-tracking monitor, add it if clicks on the pill body are ever missed underneath.
        let host = NSHostingView(rootView: DictationPillView(dictation: dictation) { [weak self] in self?.resize(to: $0) })
        host.sizingOptions = []   // the panel follows the content through `resize`, not the other way round
        panel.contentView = host
    }

    /// The content height changed: the bottom edge and the centre stay put, so the pill grows upwards.
    private func resize(to height: CGFloat) {
        DispatchQueue.main.async { [panel] in
            var frame = panel.frame
            guard abs(frame.height - height) > 0.5 else { return }
            frame.size.height = height
            panel.setFrame(frame, display: true)
        }
    }

    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2, y: area.minY + 64))
        }
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

/// Reports the pill's laid-out height so the panel can follow it.
private struct PillHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct DictationPillView: View {
    @ObservedObject var dictation: DictationController
    var onHeight: (CGFloat) -> Void = { _ in }

    var body: some View {
        Group {
            if let offer = dictation.offering, dictation.state == .idle { suggestion(offer) } else { status }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { Color.clear.preference(key: PillHeight.self, value: $0.size.height) })
        .onPreferenceChange(PillHeight.self) { if $0 > 0 { onHeight($0) } }
    }

    /// A learnt correction (opt-in): add it to the vocabulary, or not.
    private func suggestion(_ offer: AutoLearn.Correction) -> some View {
        HStack(spacing: 8) {
            Text("Always type “\(offer.typed)” for “\(offer.heard)”?")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { dictation.acceptSuggestion(offer) } label: {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add to vocabulary")
            Button { dictation.dismissSuggestion(offer) } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Not now")
        }
        .padding(.horizontal, 14)
        .frame(width: DictationPill.width, height: 44)
        .background(.regularMaterial, in: Capsule())
    }

    private var status: some View {
        var recording = false
        if case .recording = dictation.state { recording = true }
        return DictationPillStatus(message: message, levels: dictation.levels, recording: recording) {
            try? dictation.cancel(caller: DictationController.user)
        }
    }

    private var message: String {
        switch dictation.state {
        case .idle: ""
        case .recording(_, let partial): dictation.preparing && partial.isEmpty ? "Preparing…" : partial.isEmpty ? dictation.micNotice ?? "Listening" : partial
        case .transcribing: dictation.lastPartial.isEmpty ? "Transcribing…" : dictation.lastPartial
        case .done(let text): text
        case .failed(let reason): reason
        }
    }
}

/// Text on top (the newest words, up to 3 lines), the level meter underneath, ✕ at the top right. Stateless, so the
/// UI snapshots can render every state.
struct DictationPillStatus: View {
    let message: String
    let levels: [Float]
    let recording: Bool
    let cancel: () -> Void

    private static let accent = Color(red: 1, green: 0xD2 / 255, blue: 0x1F / 255)   // #FFD21F
    private static let keep = 96   // characters: about three lines at this size; the end of the text, never the start
    private static let bars = 48    // 4 pt wide, 5 pt apart: the 11 levels spread over the pill's width

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text(Self.tail(message))
                    .font(.system(size: 18, weight: .medium))
                    .lineLimit(3)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Dictation: \(message)")
                Button(action: cancel) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel dictation")
            }
            if recording { meter }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: DictationPill.width)
        .frame(minHeight: 72)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var meter: some View {
        HStack(spacing: 5) {
            ForEach(0..<Self.bars, id: \.self) { i in
                Capsule().fill(Self.accent).frame(width: 4, height: 3 + CGFloat(level(at: i)) * 17)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 20)
        .accessibilityHidden(true)
    }

    /// The levels, linearly interpolated across the bars.
    private func level(at bar: Int) -> Float {
        guard levels.count > 1 else { return levels.first ?? 0 }
        let x = Float(bar) / Float(Self.bars - 1) * Float(levels.count - 1)
        let i = min(Int(x), levels.count - 2)
        return levels[i] + (levels[i + 1] - levels[i]) * (x - Float(i))
    }

    /// The last `keep` characters from a word boundary, "…" in front when the start was dropped.
    static func tail(_ text: String) -> String {
        guard text.count > keep else { return text }
        let end = text.suffix(keep)
        let words = end.drop { $0 != " " }.dropFirst()
        return "…" + (words.isEmpty ? String(end) : String(words))
    }
}
