import AppKit
import SwiftUI
import TalkReadCore

// MARK: - Home

struct HomePane: View {
    @ObservedObject var model: AppModel
    let data: ViewData
    let router: WindowRouter
    @State private var text = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxl) {
                if let issue = data.setupIssue { SetupBanner(text: issue) { router.openOnboarding() } }
                editor
                hint
                HomeHistory(model: model, data: data)
            }
            .padding(Space.spacious)
            .frame(maxWidth: 880)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.surface)
        .navigationTitle("Home")
    }

    private var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var editor: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .font(TypeStyle.body)
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, Space.lg).padding(.top, Space.lg)
                .frame(minHeight: 180)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Paste or type text to listen to it")
                            .font(TypeStyle.body).foregroundStyle(.tertiary)
                            .padding(.leading, Space.xl).padding(.top, Space.lg)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Text to read aloud")
            HStack(spacing: Space.lg) {
                let words = text.split(whereSeparator: \.isWhitespace).count
                Text(words == 1 ? "1 word" : "\(words) words").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if !text.isEmpty { Button("Clear") { text = "" }.buttonStyle(.borderless) }
                PlayButton(size: 40) { play() }
                    .disabled(isBlank)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Read aloud (⌘↩)")
            }
            .padding(.horizontal, Space.lg).padding(.vertical, Space.md)
        }
        .card(padding: 0)
    }

    private func play() {
        guard !isBlank else { return }
        do {
            router.open(try model.readPasted(text, id: model.reserve("user")).item)
        } catch let error as AppError {
            MiniPlayer.shared.flash(error.message)
        } catch {
            MiniPlayer.shared.flash(error.localizedDescription)
        }
    }

    private var hint: some View {
        HStack(spacing: Space.lg) {
            IconTile(symbol: "text.cursor", size: 38)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Read anything on your Mac").font(.headline)
                Text("Use Read selection: select text in any app and press the shortcut. Press it again to stop.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: Space.md)
            KeyCaps(display: model.settings.readShortcut.display)
        }
        .card()
    }

    static func caption(_ app: String?, _ date: Date) -> String {
        let when = date.formatted(.relative(presentation: .named))
        return app.map { "\($0) · \(when)" } ?? when
    }
}

/// "Hold the right Option key and speak", following the setting.
func holdHint(_ s: TalkReadCore.Settings) -> String {
    switch s.dictationHoldKey {
    case .rightOption: "Hold the right Option key and speak"
    case .fn: "Hold Fn and speak"
    case .rightCommand: "Hold the right Command key and speak"
    case .off: "Press \(s.dictationToggleShortcut.display) and speak"
    }
}

struct SetupBanner: View {
    let text: String
    let action: () -> Void
    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.title3).foregroundStyle(Theme.warning)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.md)
            Button("Finish setting up", action: action).buttonStyle(AccentButtonStyle())
        }
        .padding(Space.lg)
        .background(Theme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.warning.opacity(0.4)))
        .accessibilityElement(children: .contain)
    }
}

struct EmptyNote: View {
    let text: String
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.lg)
    }
}

/// Copies on purpose (the user asked), so the pasteboard is not restored afterwards.
struct CopyButton: View {
    let text: String
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Copy")
        .accessibilityLabel("Copy")
    }
}

