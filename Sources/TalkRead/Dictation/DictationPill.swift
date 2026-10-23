// Non-activating capsule near the bottom centre of the screen with the pointer: level meter, state, cancel. Never key
// or main; Esc cancels through the hotkey tap, not here.
import AppKit
import SwiftUI
import TalkReadCore

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

    private static let accent = Color(red: 1, green: 0xD2 / 255, blue: 0x1F / 255)   // #FFD21F

    var body: some View {
        if let offer = dictation.offering, dictation.state == .idle { suggestion(offer) } else { status }
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
        .frame(width: 240, height: 44)
        .background(.regularMaterial, in: Capsule())
    }

    private var status: some View {
        HStack(spacing: 10) {
            if case .recording = dictation.state {
                HStack(spacing: 2) {
                    ForEach(dictation.levels.indices, id: \.self) { i in
                        Capsule().fill(Self.accent).frame(width: 3, height: 4 + CGFloat(dictation.levels[i]) * 20)
                    }
                }
                .frame(width: 54, height: 24)
                .accessibilityHidden(true)
            }
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.head)
                .minimumScaleFactor(0.85)
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
    }

    private var message: String {
        switch dictation.state {
        case .idle: ""
        case .recording(_, let partial): dictation.preparing && partial.isEmpty ? "Preparing…" : partial.isEmpty ? "Listening" : partial
        case .transcribing: dictation.lastPartial.isEmpty ? "Transcribing…" : dictation.lastPartial
        case .done(let text): text
        case .failed(let reason): reason
        }
    }
}
