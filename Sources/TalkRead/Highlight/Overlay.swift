// One click-through panel per screen drawing the word box and the sentence tint (ported from ReadAlong). Never takes
// focus or clicks; no panel exists while idle (closed two seconds after the last hide).
import AppKit
import TalkReadCore

@MainActor final class Overlay {
    struct Style {
        var wordColor: NSColor = NSColor(srgbRed: 1, green: 0.824, blue: 0.122, alpha: 1)   // #FFD21F
        var sentenceColor: NSColor = NSColor(srgbRed: 1, green: 0.824, blue: 0.122, alpha: 0.35)
        var opacity: CGFloat = 0.85
        var tintEnabled = true

        init() {}

        /// From Settings: `highlightHex`, `tintEnabled`, `opacity`. The tint is the same hue at 35 %.
        init(_ settings: Settings) {
            if let rgb = Int(settings.highlightHex.dropFirst(), radix: 16) {
                wordColor = NSColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
                sentenceColor = wordColor.withAlphaComponent(0.35)
            }
            opacity = CGFloat(settings.opacity)
            tintEnabled = settings.tintEnabled
        }
    }
    var style: Style

    /// Never key or main, whatever AppKit asks.
    final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// One borderless panel per screen, its word box layer and a reusable pool of tint layers (a wrapped sentence can
    /// span several rects).
    final class ScreenPanel {
        let panel: Panel
        let wordLayer = CALayer()
        private let root: CALayer
        private var tintLayers: [CALayer] = []

        init(screen: NSScreen) {
            let panel = Panel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false  // ARC owns it; close() only frees the window server side
            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            panel.contentView = view
            root = view.layer!
            self.panel = panel
            wordLayer.cornerRadius = 5
            wordLayer.borderWidth = 1.5
            wordLayer.isHidden = true
            root.addSublayer(wordLayer)
        }

        /// Reuses layers across calls instead of tearing down every tick.
        func setTint(_ rects: [CGRect], color: CGColor) {
            while tintLayers.count < rects.count {
                let layer = CALayer()
                layer.actions = ["frame": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull()]
                layer.cornerRadius = 4
                root.insertSublayer(layer, below: wordLayer)
                tintLayers.append(layer)
            }
            for (i, layer) in tintLayers.enumerated() {
                layer.isHidden = i >= rects.count
                if i < rects.count {
                    layer.frame = rects[i]
                    layer.backgroundColor = color
                }
            }
        }
    }

    private(set) var panels: [ScreenPanel] = []
    private let screens: () -> [NSScreen]
    private var isFrontmost = false
    private var screenObserver: NSObjectProtocol?
    private var orderedAt: TimeInterval = 0
    private var hideGeneration = 0
    /// Set when a panel had to be brought back onto the active Space; the Highlighter logs it once.
    var reorderedOffSpace = false
    private var loggedThisRead = false

    /// `screens` is every screen; the self-test passes the Prompter XL alone.
    init(style: Style, screens: @escaping () -> [NSScreen] = { NSScreen.screens }) {
        self.style = style
        self.screens = screens
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.closePanels() } }   // the next show builds them for the new screens
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }   // panels close as they deallocate
    }

    /// Cocoa screen coordinates. A nil word hides the box; an empty sentence hides the tint.
    func show(word: CGRect?, sentence: [CGRect]) {
        hideGeneration += 1
        // A panel that lived through a full-screen Space switch can stay off that Space even when re-ordered (macOS 27.2,
        // 25 Sep), while a new panel joins it. So every read starts on new panels, and a panel still off the active Space
        // a second after being ordered in over the word is replaced. occlusionState comes from what the window server
        // composited; isOnActiveSpace can be stale.
        let now = ProcessInfo.processInfo.systemUptime
        let offSpace = isFrontmost && now - orderedAt > 1 && panels.contains { p in
            word.map { p.panel.frame.intersects($0) } == true
                && (!p.panel.occlusionState.contains(.visible) || !p.panel.isOnActiveSpace)
        }
        if !isFrontmost || offSpace {
            closePanels()
            panels = screens().map { ScreenPanel(screen: $0) }
            for p in panels { p.panel.orderFrontRegardless() }
            isFrontmost = true
            orderedAt = now
            if offSpace, !loggedThisRead { reorderedOffSpace = true; loggedThisRead = true }
        }

        let wordFill = style.wordColor.withAlphaComponent(min(style.opacity, 0.5)).cgColor   // the fill never hides the word
        let wordStroke = style.wordColor.withAlphaComponent(min(style.opacity + 0.2, 1)).cgColor
        for p in panels {
            let origin = p.panel.frame.origin
            let bounds = CGRect(origin: .zero, size: p.panel.frame.size)
            let tint = style.tintEnabled ? sentence.compactMap { r -> CGRect? in
                let moved = r.offsetBy(dx: -origin.x, dy: -origin.y).intersection(bounds)
                return moved.isNull ? nil : moved
            } : []
            p.setTint(tint, color: style.sentenceColor.cgColor)

            if let word {
                let moved = word.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: -2, dy: -1)
                if !moved.intersection(bounds).isNull {
                    p.wordLayer.backgroundColor = wordFill
                    p.wordLayer.borderColor = wordStroke
                    CATransaction.begin()
                    if p.wordLayer.isHidden {
                        CATransaction.setDisableActions(true)   // first appearance: snap, don't slide in from a stale frame
                    } else {
                        CATransaction.setAnimationDuration(0.12)
                    }
                    p.wordLayer.frame = moved
                    p.wordLayer.isHidden = false
                    CATransaction.commit()
                    continue
                }
            }
            p.wordLayer.isHidden = true
        }
    }

    /// Orders the panels out now and closes them two seconds later unless something was shown meanwhile.
    func hide() {
        guard isFrontmost else { return }
        for p in panels {
            p.wordLayer.isHidden = true
            p.setTint([], color: .clear)
            p.panel.orderOut(nil)
        }
        isFrontmost = false
        loggedThisRead = false
        hideGeneration += 1
        let generation = hideGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.hideGeneration == generation else { return }
            self.closePanels()
        }
    }

    private func closePanels() {
        for p in panels { p.panel.close() }
        panels = []
        isFrontmost = false
    }
}
