// First run: welcome, permissions (live ticks), model downloads with sizes and progress, and a try-it step. Owned by WP6.
import AppKit
import SwiftUI
import TalkReadCore

/// Root for the onboarding window. `onFinish` closes it (the lead's window code).
struct OnboardingView: View {
    @ObservedObject var model: AppModel
    var onFinish: () -> Void = {}

    var body: some View {
        OnboardingContent(model: model, data: model.viewData, onFinish: onFinish)
            .task {   // live permission ticks
                while !Task.isCancelled {
                    model.refreshPermissions()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
    }
}

struct OnboardingContent: View {
    @ObservedObject var model: AppModel
    let data: ViewData
    var onFinish: () -> Void
    @State var step = 0
    @State private var tryText = ""

    static let sample = "Talk & Read follows along as it reads. Each word lights up as you hear it, so your eyes and ears stay together."

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: permissions
                case 2: voices
                default: tryIt
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 40).padding(.top, 36)
            Divider()
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    ForEach(0..<4, id: \.self) { i in
                        Capsule().fill(i == step ? Theme.accent : Color.primary.opacity(0.15)).frame(width: i == step ? 18 : 7, height: 7)
                    }
                }
                .accessibilityElement().accessibilityLabel("Step \(step + 1) of 4")
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                Button(step == 3 ? "Start using Talk & Read" : "Continue", action: next)
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 600, height: 540)
        .background(Theme.surface)
        .tint(Theme.accent)
    }

    private func next() {
        if step < 3 { step += 1; return }
        model.settings.onboardingDone = true
        onFinish()
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 116, height: 116).accessibilityHidden(true)
            Text("Welcome to Talk & Read").font(.largeTitle.weight(.semibold))
            VStack(spacing: 8) {
                Text("Select text anywhere and hear it read aloud, each word highlighted as it is spoken.")
                Text("Hold a key, speak, and your words are typed where your cursor is.")
            }
            .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Label("Everything runs on this Mac. Nothing you read or say leaves it.", systemImage: "lock")
                .font(.callout).foregroundStyle(.secondary).padding(.top, 6)
        }
        .padding(.top, 12)
    }

    private func header(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 20) {
            header("Allow access", "macOS asks you to approve each of these once. The ticks appear as soon as you allow them.")
            VStack(spacing: 0) {
                PermissionRow(symbol: "accessibility", title: "Accessibility", detail: "Needed to read selected text, highlight words and type dictation.",
                              granted: data.permissions.accessibility) { model.request(.accessibility) }
                Divider().padding(.leading, 64)
                PermissionRow(symbol: "mic", title: "Microphone", detail: "Needed for dictation. Audio stays on this Mac.",
                              granted: data.permissions.microphone) { model.request(.microphone) }
                Divider().padding(.leading, 64)
                PermissionRow(symbol: "rectangle.dashed.badge.record", title: "Screen Recording (optional)",
                              detail: "Only for apps that hide their text, so the highlight can still find words.",
                              granted: data.permissions.screenRecording) { model.request(.screenRecording) }
            }
            .card(padding: 0)
        }
    }

    private var voices: some View {
        let total = ModelStatusRow.megabytes(.voice, data.voiceModel) + ModelStatusRow.megabytes(.dictation, data.dictationModel)
        let busy = [data.voiceModel, data.dictationModel].contains { if case .downloading = $0 { true } else { false } }
        let done = data.voiceModel == .ready && data.dictationModel == .ready
        return VStack(alignment: .leading, spacing: 20) {
            header("Download the voices", "A natural voice and a dictation model. They download once, then work offline.")
            VStack(spacing: 0) {
                ModelStatusRow(kind: .voice, state: data.voiceModel)
                Divider().padding(.leading, 64)
                ModelStatusRow(kind: .dictation, state: data.dictationModel)
            }
            .card(padding: 0)
            HStack(spacing: 16) {
                if !done {
                    Button(busy ? "Downloading…" : "Download both, \(total) MB") { model.downloadModels() }
                        .buttonStyle(AccentButtonStyle()).disabled(busy)
                    Button("Skip, use the built-in voices") { step += 1 }.buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            Text("The built-in Apple voices work straight away. Dictation needs its model.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 20) {
            header("Try it", "Press play to hear the sample. Then click in the box and dictate something.")
            HStack(alignment: .top, spacing: 16) {
                Text(Self.sample).font(.system(size: 17)).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                PlayButton(size: 44) { try? model.speak(Self.sample, title: "Welcome", caller: "user") }
            }
            .card()
            VStack(alignment: .leading, spacing: 8) {
                TextField("Dictation test", text: $tryText, prompt: Text(holdHint(model.settings)), axis: .vertical)
                    .lineLimit(3...5)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 6) {
                    Text("Anywhere on your Mac, select text and press").foregroundStyle(.secondary)
                    KeyCaps(display: model.settings.readShortcut.display)
                    Text("to hear it.").foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }
}
