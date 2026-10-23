// The word box and sentence tint, pinned to the window being read (H2). One click-through panel the size of that window,
// ordered directly above it at its level: it moves with the window, anything that covers the window covers the box,
// and it is closed while the window is off screen (another Space, minimised, hidden, closed), so it never floats over
// other apps or follows the user to another desktop. Never takes focus or clicks; no panel exists while idle.
import AppKit
import TalkReadCore

@MainActor final class Overlay {
    struct Style {
        /// H1: today's look is `.box`; the others are for a Settings ▸ Highlight style row.
        enum Shape: String { case box, outline, underline }
        var wordColor: NSColor = NSColor(srgbRed: 1, green: 0.824, blue: 0.122, alpha: 1)   // #FFD21F
        var sentenceColor: NSColor = NSColor(srgbRed: 1, green: 0.824, blue: 0.122, alpha: 0.35)
        var opacity: CGFloat = 0.85
        var tintEnabled = true
        var shape = Shape.box

        init() {}

        /// From Settings: `highlightHex`, `tintEnabled`, `opacity`. The tint is the same hue at 35 %.
        init(_ settings: Settings) {
            if let rgb = Int(settings.highlightHex.dropFirst(), radix: 16) {
                wordColor = NSColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
                sentenceColor = wordColor.withAlphaComponent(0.35)
            }
            opacity = CGFloat(settings.opacity)
            tintEnabled = settings.tintEnabled
            shape = Shape(rawValue: settings.highlightStyle) ?? .box
        }
    }
    var style: Style

    /// Never key or main, whatever AppKit asks.
    final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// The window the highlight belongs to. nil: nothing is drawn (the box never floats free).
    var source: CGWindowID?
    private(set) var panel: Panel?
    let wordLayer = CALayer()
    private var tintLayers: [CALayer] = []
    /// What is drawn, relative to the window's top-left corner, so a move or a top-edge resize keeps it on the text.
    private var word: CGRect?
    private var sentence: [CGRect] = []
    private var orderedLastFollow = false
    private var orderedAt: TimeInterval = 0
    private var createdAt: TimeInterval = 0

    init(style: Style) {
        self.style = style
        wordLayer.isHidden = true
    }

    /// Puts the panel on the source window: closed when the window is off screen, else sized to it and ordered directly
    /// above it when anything moved it out of place. One window-server query; returns whether the window is on screen.
    @discardableResult func follow() -> Bool {
        guard let source else { closePanel(); return false }
        guard case .shown(let bounds, let layer, let order) = WindowPin.placement(WindowPin.snapshot(above: source), source: source,
                                                                                 panel: panel.map { CGWindowID($0.windowNumber) })
        else {
            closePanel()   // a new panel joins whatever Space the window is on when it comes back
            return false
        }
        let frame = Locator.convert(topLeftScreenRect: bounds)
        let now = ProcessInfo.processInfo.systemUptime
        var reorder = order != .directlyAbove
        // An order reaches the window list only once the run loop has committed it: judge it from 50 ms on.
        if reorder, panel != nil, now - orderedAt < 0.05 { reorder = false }
        // An order that did not take: the panel is stuck on another Space (macOS 27.2 keeps an old panel off a Space it
        // re-enters, 25 Sep; a window dragged to another desktop stays on screen). A new panel joins the window's Space.
        if panel == nil || reorder && order == .missing && orderedLastFollow && now - createdAt > 1 {
            closePanel()
            panel = makePanel(frame)
            createdAt = now
            reorder = true
            layout(animated: false)   // a read paused off screen shows its word again on return
        }
        guard let panel else { return false }
        if panel.level.rawValue != layer { panel.level = NSWindow.Level(rawValue: layer) }
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
            layout(animated: false)
        }
        if reorder {
            panel.order(.above, relativeTo: Int(source))
            orderedAt = now
            orderedLastFollow = true
        } else if now - orderedAt >= 0.05 {
            orderedLastFollow = false
        }
        return true
    }

    /// Cocoa screen coordinates; call after `follow()` returned true. A nil word hides the box; an empty sentence the tint.
    func show(word: CGRect?, sentence: [CGRect]) {
        guard let frame = panel?.frame else { return }
        func relative(_ r: CGRect) -> CGRect { CGRect(x: r.minX - frame.minX, y: frame.maxY - r.maxY, width: r.width, height: r.height) }
        self.word = word.map(relative)
        self.sentence = style.tintEnabled ? sentence.map(relative) : []
        layout(animated: true)
    }

    /// The read ended: no panel while idle.
    func hide() {
        (word, sentence) = (nil, [])
        closePanel()
    }

    private func makePanel(_ frame: CGRect) -> Panel {
        let panel = Panel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // One Space, the window's (no .canJoinAllSpaces); allowed beside a full-screen window; left out of Mission
        // Control, Stage Manager and window cycling.
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary, .ignoresCycle]
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false   // ARC owns it; close() only frees the window server side
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        wordLayer.removeFromSuperlayer()
        tintLayers.forEach { $0.removeFromSuperlayer() }
        tintLayers = []
        wordLayer.isHidden = true
        view.layer!.addSublayer(wordLayer)
        return panel
    }

    private func closePanel() {
        panel?.close()
        panel = nil
        orderedLastFollow = false
    }

    /// Places the layers from the window-relative rects (top-left origin) in the panel's own (bottom-left) space.
    private func layout(animated: Bool) {
        guard let panel, let root = wordLayer.superlayer else { return }
        let height = panel.frame.height
        func local(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height) }

        while tintLayers.count < sentence.count {   // reused across ticks; a wrapped sentence spans several rects
            let layer = CALayer()
            layer.actions = ["frame": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull()]
            layer.cornerRadius = 4
            root.insertSublayer(layer, below: wordLayer)
            tintLayers.append(layer)
        }
        for (i, layer) in tintLayers.enumerated() {
            layer.isHidden = i >= sentence.count
            if i < sentence.count {
                layer.frame = local(sentence[i])
                layer.backgroundColor = style.sentenceColor.cgColor
            }
        }

        guard let word else { wordLayer.isHidden = true; return }
        let fill = style.wordColor.withAlphaComponent(min(style.opacity, 0.5)).cgColor   // the fill never hides the word
        let stroke = style.wordColor.withAlphaComponent(min(style.opacity + 0.2, 1)).cgColor
        let frame: CGRect
        switch style.shape {
        case .box, .outline:
            frame = word.insetBy(dx: -2, dy: -1)
            wordLayer.cornerRadius = 5
            wordLayer.borderWidth = style.shape == .box ? 1.5 : 2
            wordLayer.borderColor = stroke
            wordLayer.backgroundColor = style.shape == .box ? fill : nil
        case .underline:
            frame = CGRect(x: word.minX, y: word.maxY, width: word.width, height: 3)
            wordLayer.cornerRadius = 1.5
            wordLayer.borderWidth = 0
            wordLayer.backgroundColor = stroke
        }
        CATransaction.begin()
        if !animated || wordLayer.isHidden {
            CATransaction.setDisableActions(true)   // first appearance or a window move: snap, don't slide
        } else {
            CATransaction.setAnimationDuration(0.12)
        }
        wordLayer.frame = local(frame)
        wordLayer.isHidden = false
        CATransaction.commit()
    }
}
