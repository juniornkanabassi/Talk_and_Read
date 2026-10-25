// Floating mini player: a non-activating glass panel with transport controls and a karaoke line (or three-line
// subtitles). Shows when a read starts, hides a few seconds after it ends, remembers where it was dragged. Owned by WP6.
// A dictation while it is on screen docks into it: one card, dictation on top, the read underneath (Junior, 25 Oct).
import AppKit
import Combine
import SwiftUI
import TalkReadCore

/// The panel controller. The app calls `attach(_:)` once at launch, `flash(_:)` for reads that never start
/// ("Select some text first"), and `toggle()` from the menu.
@MainActor final class MiniPlayer: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = MiniPlayer()

    @Published private(set) var message: String?
    /// On screen (the dictation pill watches it to dock in or move back out).
    @Published private(set) var isShowing = false
    /// The dictation shown on top of the read while both are up; nil otherwise. The pill docks and undocks it.
    @Published private(set) var docked: DictationController?
    /// The docked dictation's height, divider included (0 when none); the panel grows upwards by it.
    private var dockedHeight: CGFloat = 0
    private var panel: MiniPanel?
    private weak var model: AppModel?
    private var sessionWatch: AnyCancellable?
    private var stateWatch: AnyCancellable?
    private var noticeWatch: AnyCancellable?
    /// The read fell back to Kokoro (V3): the panel grows by one line for the notice.
    private var hasNotice = false
    private var hideTask: Task<Void, Never>?
    private var sentenceCache: (id: ObjectIdentifier, ranges: [Range<Int>])?

    var isVisible: Bool { panel?.isVisible == true }

    /// On screen on the current Space, so a dictation docked into it is seen.
    var canDock: Bool { panel.map { $0.isVisible && $0.isOnActiveSpace } ?? false }

    /// The pointer is over the player (a docked dictation's hide waits, as over its own pill).
    var containsPointer: Bool { panel.map { $0.isVisible && NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? false }

    func dock(_ dictation: DictationController) {
        guard docked !== dictation else { return }
        docked = dictation
        dockedHeight = MiniPlayerView.dockEstimate   // until the dictation reports its laid-out height
        resize()
    }

    func undock(_ dictation: DictationController) {
        guard docked === dictation else { return }
        docked = nil
        dockedHeight = 0
        resize()
    }

    /// The docked dictation laid out at `height`; the panel follows on the next turn (not during layout).
    fileprivate func dockedHeightChanged(_ height: CGFloat) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.docked != nil else { return }
            let total = height + MiniPlayerView.dockDivider
            guard abs(total - self.dockedHeight) > 0.5 else { return }
            self.dockedHeight = total
            self.resize()
        }
    }

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
        if !isShowing { isShowing = true }
    }

    func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
        message = nil
        if isShowing { isShowing = false }   // a docked dictation moves back to its own pill
    }

    func toggle() { isVisible ? hide() : show() }

    /// A short status with no read behind it; hides after the usual delay.
    func flash(_ text: String) {
        message = text
        hasNotice = false   // a message replaces the read's face, notice included
        resize()
        show()
        hideLater()
    }

    /// Close button and Esc: stop reading and hide.
    func close() {
        if model?.session != nil { model?.stopReading() }
        hide()
    }

    /// Height follows the subtitles setting, the fallback notice and a docked dictation; the bottom edge stays put.
    func resize() {
        guard let panel, let model else { return }
        let height = MiniPlayerView.height(expanded: model.settings.subtitlesExpanded, notice: hasNotice) + dockedHeight
        panel.setContentSize(NSSize(width: MiniPlayerView.width, height: height))
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
        hasNotice = false
        noticeWatch = session?.$fallbackReason.map { $0 != nil }.removeDuplicates().sink { [weak self] on in
            self?.hasNotice = on
            self?.resize()
        }
        if session != nil, model?.settings.showMiniPlayer == true { show() }
    }

    /// A docked dictation holds the player until it has gone, so the card never splits in two mid-sentence.
    private func hideLater() {
        hideTask?.cancel()
        let seconds = Double(model?.settings.miniPlayerAutoHideSeconds ?? 3)
        guard seconds > 0 else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            while !Task.isCancelled, self?.docked != nil { try? await Task.sleep(for: .seconds(0.5)) }
            if !Task.isCancelled { self?.hide() }
        }
    }

    private func makePanel(_ model: AppModel) -> MiniPanel {
        let size = NSSize(width: MiniPlayerView.width, height: MiniPlayerView.height(expanded: model.settings.subtitlesExpanded, notice: hasNotice))
        let panel = MiniPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.contentView = NSHostingView(rootView: MiniPlayerRoot(model: model, player: self))
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
        panel.setAccessibilityLabel("Talk & Read player")
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

/// The panel's content: the player alone, or one card with a docked dictation on top.
private struct MiniPlayerRoot: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: MiniPlayer

    var body: some View {
        if let dictation = player.docked {
            CombinedCard {
                DictationPillView(dictation: dictation, docked: true) { player.dockedHeightChanged($0) }
            } player: {
                MiniPlayerLive(model: model, player: player, surface: false)
            }
        } else {
            MiniPlayerLive(model: model, player: player)
        }
    }
}

/// Dictation and reading at once: the dictation on top, a hairline, the player underneath, on one surface.
struct CombinedCard<Dictation: View, Player: View>: View {
    @ViewBuilder let dictation: Dictation
    @ViewBuilder let player: Player

    var body: some View {
        VStack(spacing: 0) {
            dictation
            Rectangle().fill(.separator).frame(height: MiniPlayerView.dockDivider).padding(.horizontal, 16)
            player
        }
        .frame(width: MiniPlayerView.width)
        .panelSurface(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dictation and player")
    }
}

/// Live content: the model's current session, or the controller's status message.
private struct MiniPlayerLive: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: MiniPlayer
    /// false inside the combined card, which draws the surface.
    var surface = true

    var body: some View {
        if let session = model.session, player.message == nil {
            MiniPlayerSession(model: model, player: player, session: session, surface: surface)
        } else {
            MiniPlayerView(model: model, voices: model.voices, line: nil, state: nil, status: player.message ?? "Ready",
                           note: nil, voiceName: VoiceGroups.name(model.settings.voiceID, in: model.voices), notice: nil,
                           expanded: expanded, close: player.close, surface: surface)
        }
    }

    private var expanded: Binding<Bool> { MiniPlayerView.expandedBinding(model, player) }
}

private struct MiniPlayerSession: View {
    @ObservedObject var model: AppModel
    let player: MiniPlayer
    @ObservedObject var session: ReadSession
    var surface = true

    var body: some View {
        let line = ReadingText.karaoke(text: session.text, tokens: session.tokens, sentences: player.sentences(for: session), token: session.currentToken)
        MiniPlayerView(model: model, voices: model.voices, line: session.state == .finished ? nil : line, state: session.state,
                       status: status, note: session.capture?.source == .clipboard ? "Reading clipboard" : nil,
                       voiceName: session.effectiveVoice.name, notice: session.fallbackReason,
                       expanded: MiniPlayerView.expandedBinding(model, player), close: player.close, surface: surface)
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
    static func height(expanded: Bool, notice: Bool = false) -> CGFloat { (expanded ? 196 : 96) + (notice ? noticeHeight : 0) }
    static let noticeHeight: CGFloat = 22
    /// The hairline between a docked dictation and the read.
    static let dockDivider: CGFloat = 1
    /// A docked dictation's height before it reports one (one line and the meter), hairline included.
    static let dockEstimate: CGFloat = 73

    @ObservedObject var model: AppModel
    let voices: [Voice]
    let line: KaraokeLine?
    let state: ReadSession.State?
    /// Shown instead of the line when there is no word yet ("Preparing…", "Select some text first", "Done").
    let status: String
    /// Small note beside the controls ("Reading clipboard").
    let note: String?
    /// The voice speaking now (the session's effective voice, so a fallback shows), on the voice menu.
    let voiceName: String
    /// `ReadSession.fallbackReason`: one line above the words while the read uses the Kokoro fallback (V3).
    let notice: String?
    @Binding var expanded: Bool
    let close: () -> Void
    /// false inside the combined card with a dictation, which draws one surface round both.
    var surface = true

    static func expandedBinding(_ model: AppModel, _ player: MiniPlayer) -> Binding<Bool> {
        Binding(get: { model.settings.subtitlesExpanded }, set: { model.settings.subtitlesExpanded = $0; player.resize() })
    }

    private var active: Bool { state == .playing || state == .paused || state == .preparing }

    var body: some View {
        if surface { face.panelSurface(RoundedRectangle(cornerRadius: 26, style: .continuous)) } else { face }
    }

    private var face: some View {
        VStack(spacing: 6) {
            if let notice {
                Label { Text(notice).lineLimit(1).truncationMode(.tail) } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.accent)
                }
                .font(.caption).foregroundStyle(.secondary)
                .frame(height: Self.noticeHeight - 6)
                .padding(.horizontal, 22)
                .help(notice)
                .accessibilityElement(children: .combine)
            }
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
        .frame(width: Self.width, height: Self.height(expanded: expanded, notice: notice != nil))
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
            SpeedControl(speed: Double(model.activeSpeed)) { model.setSpeed(Float($0)) }   // a 1x preview shows 1x
                .frame(width: 56, height: 24)
            VoiceMenu(voices: voices, english: model.settings.voiceID, french: model.settings.frenchVoiceID, title: voiceName) { model.setVoice($0) }
                .help("Reading with \(voiceName). A new choice applies to the next read.")
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
        return wordPattern.matches(in: s, range: NSRange(location: 0, length: ns.length)).map {
            (ns.substring(with: $0.range), $0.range.location..<NSMaxRange($0.range))
        }
    }
    /// Compiled once, not on every word change.
    private static let wordPattern = try! NSRegularExpression(pattern: "\\S+")
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

/// "1.50×": click to choose 1×, 1.5×, 2×, 2.5× or 3×; scroll to fine-tune. AppKit, because SwiftUI has no scroll-wheel hook.
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
            action = #selector(showMenu)
            toolTip = "Click to choose 1×, 1.5×, 2×, 2.5× or 3×; scroll to fine-tune"
            setAccessibilityLabel("Speed")
        }
        required init?(coder: NSCoder) { fatalError("not used") }

        static func presetItems(current: Double) -> [(title: String, value: Double, on: Bool)] {
            presets.map { (title: Theme.speed($0), value: $0, on: abs($0 - current) < 0.001) }
        }

        @objc private func showMenu() {
            let menu = NSMenu()
            for item in Self.presetItems(current: speed) {
                let menuItem = NSMenuItem(title: item.title, action: #selector(choose(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = item.value
                menuItem.state = item.on ? .on : .off
                menu.addItem(menuItem)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
        }

        @objc private func choose(_ sender: NSMenuItem) {
            if let value = sender.representedObject as? Double { onChange?(value) }
        }

        override func scrollWheel(with event: NSEvent) {
            scrolled += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 10 : event.scrollingDeltaY
            let steps = scrolled.rounded(.towardZero)
            guard steps != 0 else { return }
            scrolled -= steps
            onChange?(min(3, max(0.5, ((speed + Double(steps) * 0.05) * 20).rounded() / 20)))
        }
    }
}
