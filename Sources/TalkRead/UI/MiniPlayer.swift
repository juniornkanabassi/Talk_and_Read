// Floating mini player: a non-activating glass panel with transport controls and a karaoke line (or three-line
// subtitles). Shows when a read starts, hides a few seconds after it ends, remembers where it was dragged. Owned by WP6.
import AppKit
import Combine
import SwiftUI
import TalkReadCore

/// The panel controller. The app calls `attach(_:)` once at launch, `flash(_:)` for reads that never start
/// ("Select some text first"), and `toggle()` from the menu.
@MainActor final class MiniPlayer: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = MiniPlayer()

    @Published private(set) var message: String?
    private var panel: MiniPanel?
    private weak var model: AppModel?
    private var sessionWatch: AnyCancellable?
    private var stateWatch: AnyCancellable?
    private var hideTask: Task<Void, Never>?
    private var sentenceCache: (id: ObjectIdentifier, ranges: [Range<Int>])?

    var isVisible: Bool { panel?.isVisible == true }

    func attach(_ model: AppModel) {
        self.model = model
        sessionWatch = model.$session.sink { [weak self] in self?.follow($0) }
    }

    func show() {
        guard let model else { return }
        hideTask?.cancel()
        let panel = self.panel ?? makePanel(model)
        if !panel.isVisible {
            resize()
            place(panel, saved: model.settings.miniPlayerOrigin)
            panel.orderFrontRegardless()   // never activates the app
        }
    }

    func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
        message = nil
    }

    func toggle() { isVisible ? hide() : show() }

    /// A short status with no read behind it; hides after the usual delay.
    func flash(_ text: String) {
        message = text
        show()
        hideLater()
    }

    /// Close button and Esc: stop reading and hide.
    func close() {
        if model?.session != nil { model?.stopReading() }
        hide()
    }

    /// Height follows the subtitles setting; the bottom edge stays put.
    func resize() {
        guard let panel, let model else { return }
        panel.setContentSize(NSSize(width: MiniPlayerView.width, height: MiniPlayerView.height(expanded: model.settings.subtitlesExpanded)))
    }

    /// Sentence ranges of the current session, worked out once per session.
    func sentences(for session: ReadSession) -> [Range<Int>] {
        if let c = sentenceCache, c.id == ObjectIdentifier(session) { return c.ranges }
        let ranges = ReadingText.sentenceRanges(session.tokens)
        sentenceCache = (ObjectIdentifier(session), ranges)
        return ranges
    }

    private func follow(_ session: ReadSession?) {
        message = nil
        stateWatch = session?.$state.removeDuplicates().sink { [weak self] state in
            switch state {
            case .finished, .failed: self?.hideLater()
            default: self?.hideTask?.cancel()
            }
        }
        if session != nil, model?.settings.showMiniPlayer == true { show() }
    }

    private func hideLater() {
        hideTask?.cancel()
        let seconds = Double(model?.settings.miniPlayerAutoHideSeconds ?? 3)
        guard seconds > 0 else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { self?.hide() }
        }
    }

    private func makePanel(_ model: AppModel) -> MiniPanel {
        let size = NSSize(width: MiniPlayerView.width, height: MiniPlayerView.height(expanded: model.settings.subtitlesExpanded))
        let panel = MiniPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.contentView = NSHostingView(rootView: MiniPlayerLive(model: model, player: self))
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        panel.setAccessibilityLabel("Talk and Read player")
        self.panel = panel
        return panel
    }

    /// Saved origin when it is still on a screen, else bottom centre of the main screen above the Dock.
    private func place(_ panel: NSPanel, saved: CGPoint?) {
        let size = panel.frame.size
        if let o = saved, NSScreen.screens.contains(where: { $0.visibleFrame.contains(NSPoint(x: o.x + size.width / 2, y: o.y + size.height / 2)) }) {
            panel.setFrameOrigin(o)
        } else if let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 72))
        }
    }

    // ponytail: one remembered origin (Settings.miniPlayerOrigin); falls back to the main screen if that point is gone.
    func windowDidMove(_ notification: Notification) {
        guard let panel, panel.isVisible, model?.settings.miniPlayerOrigin != panel.frame.origin else { return }
        model?.settings.miniPlayerOrigin = panel.frame.origin
    }
}

/// Non-activating, floating; becomes key only for a control that needs the keyboard, never main.
final class MiniPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Live content: the model's current session, or the controller's status message.
private struct MiniPlayerLive: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: MiniPlayer

    var body: some View {
        if let session = model.session, player.message == nil {
            MiniPlayerSession(model: model, player: player, session: session)
        } else {
            MiniPlayerView(model: model, voices: model.voices, line: nil, state: nil, status: player.message ?? "Ready",
                           note: nil, expanded: expanded, close: player.close)
        }
    }

    private var expanded: Binding<Bool> { MiniPlayerView.expandedBinding(model, player) }
}

private struct MiniPlayerSession: View {
    @ObservedObject var model: AppModel
    let player: MiniPlayer
    @ObservedObject var session: ReadSession

    var body: some View {
        let line = ReadingText.karaoke(text: session.text, tokens: session.tokens, sentences: player.sentences(for: session), token: session.currentToken)
        MiniPlayerView(model: model, voices: model.voices, line: session.state == .finished ? nil : line, state: session.state,
                       status: status, note: session.capture?.source == .clipboard ? "Reading clipboard" : nil,
                       expanded: MiniPlayerView.expandedBinding(model, player), close: player.close)
    }

    private var status: String {
        switch session.state {
        case .failed(let why): return why
        case .finished: return "Done"
        case .paused: return "Paused"
        case .preparing, .playing:
            if case .downloading(let p) = model.voiceModel { return "Preparing voice… \(Int((p * 100).rounded())) %" }
            return "Preparing…"
        }
    }
}

/// The player's face. Pure: the live wrappers above or the snapshot fill it in.
struct MiniPlayerView: View {
    static let width: CGFloat = 440
    static func height(expanded: Bool) -> CGFloat { expanded ? 196 : 96 }

    @ObservedObject var model: AppModel
    let voices: [Voice]
    let line: KaraokeLine?
    let state: ReadSession.State?
    /// Shown instead of the line when there is no word yet ("Preparing…", "Select some text first", "Done").
    let status: String
    /// Small note beside the controls ("Reading clipboard").
    let note: String?
    @Binding var expanded: Bool
    let close: () -> Void

    static func expandedBinding(_ model: AppModel, _ player: MiniPlayer) -> Binding<Bool> {
        Binding(get: { model.settings.subtitlesExpanded }, set: { model.settings.subtitlesExpanded = $0; player.resize() })
    }

    private var active: Bool { state == .playing || state == .paused || state == .preparing }

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let line {
                    if expanded { Subtitles(line: line) } else { KaraokeStrip(line: line) }
                } else {
                    Text(status).font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            controls
        }
        .padding(.top, 10).padding(.bottom, 8)
        .frame(width: Self.width, height: Self.height(expanded: expanded))
        .panelSurface(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Player")
    }

    private var controls: some View {
        HStack(spacing: 4) {
            SymbolButton(symbol: "backward.fill", label: "Previous sentence", size: 13) { model.skip(-1) }.disabled(!active)
            PlayButton(playing: state == .playing, size: 34) { model.togglePause() }.disabled(!active)
            SymbolButton(symbol: "forward.fill", label: "Next sentence", size: 13) { model.skip(1) }.disabled(!active)
            if let note { Text(note).font(.caption).foregroundStyle(.secondary).padding(.leading, 6).lineLimit(1) }
            Spacer(minLength: 6)
            SpeedControl(speed: Double(model.settings.speed)) { model.setSpeed(Float($0)) }
                .frame(width: 56, height: 24)
            VoiceMenu(voices: voices, current: model.settings.voiceID) { model.setVoice($0) }
                .labelStyle(.iconOnly)
            SymbolButton(symbol: expanded ? "chevron.down" : "chevron.up", label: expanded ? "Hide subtitles" : "Show subtitles", size: 12) { expanded.toggle() }
            SymbolButton(symbol: "xmark", label: "Close", size: 12, action: close)
        }
        .padding(.horizontal, 12)
    }
}

/// One line that keeps the spoken word (yellow pill) centred.
struct KaraokeStrip: View {
    let line: KaraokeLine

    var body: some View {
        let words = Self.words(line.current)
        let current = words.firstIndex { w in line.word.map { w.range.overlaps($0) } ?? false } ?? 0
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(words.indices, id: \.self) { i in
                        let on = i == current && line.word != nil
                        Text(words[i].text)
                            .font(.system(size: 17, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Theme.onAccent : .primary)
                            .padding(.horizontal, 4).padding(.vertical, 2)
                            .background { if on { Capsule().fill(Theme.accent) } }
                            .id(i)
                    }
                }
                .padding(.horizontal, 22)
            }
            .scrollDisabled(true)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                         .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            .onAppear { proxy.scrollTo(current, anchor: .center) }
            .onChange(of: current) { _, i in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(i, anchor: .center) } }
        }
        .accessibilityElement()
        .accessibilityLabel(line.current)
    }

    /// Whitespace-separated pieces with their UTF-16 ranges (punctuation stays attached to its word).
    static func words(_ s: String) -> [(text: String, range: Range<Int>)] {
        let ns = s as NSString
        let re = try! NSRegularExpression(pattern: "\\S+")
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map {
            (ns.substring(with: $0.range), $0.range.location..<NSMaxRange($0.range))
        }
    }
}

/// Three lines: previous (dim), current with the word highlighted, next (dim).
struct Subtitles: View {
    let line: KaraokeLine
    var body: some View {
        VStack(spacing: 5) {
            Text(line.previous ?? " ").lineLimit(1).foregroundStyle(.tertiary)
            Text(highlighted).font(.system(size: 17)).lineLimit(3).multilineTextAlignment(.center)
            Text(line.next ?? " ").lineLimit(1).foregroundStyle(.tertiary)
        }
        .font(.system(size: 14))
        .padding(.horizontal, 22)
        .accessibilityElement()
        .accessibilityLabel(line.current)
    }

    private var highlighted: AttributedString {
        var a = AttributedString(line.current)
        if let w = line.word, let r = Range(NSRange(location: w.lowerBound, length: w.count), in: a) {
            a[r].backgroundColor = Theme.accent
            a[r].foregroundColor = Theme.onAccent
        }
        return a
    }
}

/// "1.50×": click cycles 1 / 1.5 / 2 / 2.5 / 3, scrolling fine-tunes by 0.05. AppKit, because SwiftUI has no scroll-wheel hook.
struct SpeedControl: NSViewRepresentable {
    let speed: Double
    let set: (Double) -> Void

    func makeNSView(context: Context) -> SpeedButton { SpeedButton() }

    func updateNSView(_ button: SpeedButton, context: Context) {
        button.speed = speed
        button.onChange = set
        button.attributedTitle = NSAttributedString(string: Theme.speed(speed), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor])
        button.setAccessibilityValue(Theme.speed(speed))
    }

    final class SpeedButton: NSButton {
        static let presets = Theme.quickSpeeds
        var speed = 1.0
        var onChange: ((Double) -> Void)?
        private var scrolled: CGFloat = 0

        override init(frame: NSRect) {
            super.init(frame: frame)
            isBordered = false
            target = self
            action = #selector(cycle)
            toolTip = "Click for 1×, 1.5×, 2×, 2.5× or 3×; scroll to fine-tune"
            setAccessibilityLabel("Speed")
        }
        required init?(coder: NSCoder) { fatalError("not used") }

        @objc private func cycle() { onChange?(Self.next(after: speed)) }

        static func next(after speed: Double) -> Double { presets.first { $0 > speed + 0.001 } ?? presets[0] }

        override func scrollWheel(with event: NSEvent) {
            scrolled += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 10 : event.scrollingDeltaY
            let steps = scrolled.rounded(.towardZero)
            guard steps != 0 else { return }
            scrolled -= steps
            onChange?(min(3, max(0.5, ((speed + Double(steps) * 0.05) * 20).rounded() / 20)))
        }
    }
}
