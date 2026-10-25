// Non-activating pill near the bottom centre of the screen with the pointer: live text on top, level meter underneath,
// cancel at the top right. Never key or main; Esc cancels through the hotkey tap, not here.
import AppKit
import SwiftUI
import TalkReadCore

@MainActor final class DictationPill {
    static let width: CGFloat = 340   // Junior, 24 Oct: narrower, one line of words
    private let dictation: DictationController
    /// The panel on screen; nil while hidden. Internal for the self-test's window checks.
    private(set) var panel: NSPanel?

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    init(dictation: DictationController) { self.dictation = dictation }

    /// The content height changed: the bottom edge and the centre stay put, so the pill grows upwards.
    private func resize(to height: CGFloat) {
        DispatchQueue.main.async { [weak self] in
            guard let panel = self?.panel, abs(panel.frame.height - height) > 0.5 else { return }
            var frame = panel.frame
            frame.size.height = height
            panel.setFrame(frame, display: true)
        }
    }

    /// Bottom centre of the screen with the pointer; `origin` places it there instead (the self-test: outside every
    /// display). Already showing: it stays where it is. Hidden: a new panel, made where it shows. A panel ordered out and
    /// in again is kept off the Space it comes back to (a full-screen app's, another display's) on macOS 27.2: ordered in,
    /// never on screen, which hid the pill in 0.6.0 (P-B, 24 Oct). The highlight overlay makes a new panel for the same reason.
    func show(at origin: NSPoint? = nil) {
        if let panel, panel.isVisible { return panel.orderFrontRegardless() }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? .zero
        let at = origin ?? NSPoint(x: area.midX - Self.width / 2, y: area.minY + 64)
        let panel = Panel(contentRect: NSRect(origin: at, size: NSSize(width: Self.width, height: 72)),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false   // ARC owns it; close() frees the window server side
        // ponytail: the whole panel takes clicks (only Copy and the ✕ act on them); per-region pass-through needs a
        // mouse-tracking monitor, add it if clicks on the pill body are ever missed underneath.
        let host = NSHostingView(rootView: DictationPillView(dictation: dictation) { [weak self] in self?.resize(to: $0) })
        host.sizingOptions = []   // the panel follows the content through `resize`, not the other way round
        panel.contentView = host
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.close()
        panel = nil
    }

    /// The pointer is over the pill: its hide waits (hover pauses it).
    var containsPointer: Bool { panel.map { $0.isVisible && NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? false }
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
            Button {
                do { try dictation.acceptSuggestion(offer) }
                catch let error as AppError { MiniPlayer.shared.flash(error.message) }
                catch { MiniPlayer.shared.flash(error.localizedDescription) }
            } label: {
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
        var recording = false, words = false   // `words`: the message is what was said (its newest end shows)
        switch dictation.state {
        case .recording(_, let partial): recording = true; words = !partial.isEmpty
        case .transcribing: words = !dictation.lastPartial.isEmpty
        case .done: words = true
        default: break
        }
        let copyable = dictation.copyable != nil   // done, or not typed: Copy and the paste-last tip
        return DictationPillStatus(message: message, levels: dictation.levels, recording: recording, words: words,
                                   copy: copyable ? { dictation.copyResult() } : nil, copied: dictation.copied, closes: dictation.state.showsResult,
                                   tip: copyable ? DictationPillStatus.pasteTip(TalkReadCore.Settings.load().pasteLastShortcut) : nil) {
            dictation.dismiss()
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

/// One line of text (the newest words), the level meter underneath while recording, ✕ at the top right; once done or
/// not typed, Copy beside the ✕ and the paste-last tip under the text. Stateless, so the UI snapshots can render every state.
struct DictationPillStatus: View {
    let message: String
    let levels: [Float]
    let recording: Bool
    /// Spoken words keep their newest end; notices and errors ("Mic not found, using …") keep their start.
    var words = true
    /// Copies the dictation (nil: no Copy button).
    var copy: (() -> Void)? = nil
    /// Copy was just pressed: the button says so.
    var copied = false
    /// The ✕ closes a result rather than cancelling a dictation (its VoiceOver label).
    var closes = false
    /// "Didn't land? Press ⌃⌘V to paste it" (nil: hidden).
    var tip: String? = nil
    let cancel: () -> Void

    /// The tip for the paste-last shortcut as the Shortcuts page shows it; nil when that shortcut is turned off.
    static func pasteTip(_ shortcut: TalkReadCore.Settings.Shortcut) -> String? {
        shortcut.isOff ? nil : "Didn't land? Press \(shortcut.display) to paste it"
    }

    private static let accent = Color(red: 1, green: 0xD2 / 255, blue: 0x1F / 255)   // #FFD21F
    private static let keep = 44   // characters: one line at this size; the end of the text, never the start
    private static let bars = 34    // 4 pt wide, 5 pt apart: the 11 levels spread over the pill's width

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(words ? Self.tail(message) : message)
                        .font(.system(size: 18, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)   // a mic notice fits before it is cut
                        .truncationMode(words ? .head : .tail)
                        .accessibilityLabel("Dictation: \(message)")
                    if let tip {
                        Text(tip).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let copy {
                    Button(action: copy) {
                        Text(copied ? "Copied" : "Copy").font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 9).frame(height: 22)
                            .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(copied ? "Copied" : "Copy the dictation")
                }
                Button(action: cancel) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(closes ? "Close" : "Cancel dictation")
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
