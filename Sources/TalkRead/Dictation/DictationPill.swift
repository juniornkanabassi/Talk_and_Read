// Non-activating capsule near the bottom centre of the screen with the pointer: level meter, state, cancel. Never key
// or main; Esc cancels through the hotkey tap, not here.
import AppKit
import SwiftUI

@MainActor final class DictationPill {
    private let panel: NSPanel

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    init(dictation: DictationController) {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 44), styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // ponytail: the whole 240×44 capsule takes clicks (only the ✕ acts on them); per-region pass-through needs a
        // mouse-tracking monitor, add it if clicks on the capsule body are ever missed underneath.
        panel.contentView = NSHostingView(rootView: DictationPillView(dictation: dictation))
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

struct DictationPillView: View {
    @ObservedObject var dictation: DictationController
    @State private var levels = [Float](repeating: 0, count: 11)
    @State private var lastPartial = ""

    private static let accent = Color(red: 1, green: 0xD2 / 255, blue: 0x1F / 255)   // #FFD21F

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(levels.indices, id: \.self) { i in
                    Capsule().fill(Self.accent).frame(width: 3, height: 4 + CGFloat(levels[i]) * 20)
                }
            }
            .frame(width: 54, height: 24)
            .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Dictation: \(message)")
            Button {
                try? dictation.cancel(caller: DictationController.user)
            } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel dictation")
        }
        .padding(.horizontal, 14)
        .frame(width: 240, height: 44)
        .background(.regularMaterial, in: Capsule())
        .onChange(of: dictation.state) { _, state in
            switch state {
            case .recording(let level, let partial):
                levels = Array(levels.dropFirst()) + [level]
                lastPartial = partial
            case .idle: levels = levels.map { _ in 0 }; lastPartial = ""
            default: break
            }
        }
    }

    private var message: String {
        switch dictation.state {
        case .idle: ""
        case .recording(_, let partial): dictation.preparing && partial.isEmpty ? "Preparing…" : partial.isEmpty ? "Listening" : partial
        case .transcribing: lastPartial.isEmpty ? "Transcribing…" : lastPartial
        case .done(let text): text
        case .failed(let reason): reason
        }
    }
}
