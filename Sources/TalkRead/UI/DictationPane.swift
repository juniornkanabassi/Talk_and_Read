import AppKit
import SwiftUI
import TalkReadCore

// MARK: - Dictation

struct DictationPane: View {
    @ObservedObject var model: AppModel
    let data: ViewData
    @Environment(\.undoManager) private var undoManager
    @State private var query = ""
    @State var showVocabulary = false

    var body: some View {
        VStack(spacing: 0) {
            MicrophonePicker(model: model).frame(width: 420).padding(.top, Space.lg)
            Picker("Show", selection: $showVocabulary) {
                Text("History").tag(false)
                Text("Vocabulary and clean-up").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 320).padding(.vertical, Space.lg)
            if showVocabulary { vocabulary } else { history }
        }
        .background(Theme.surface)
        .navigationTitle("Dictation")
        .searchable(text: $query, prompt: "Search dictations")
    }

    private var filtered: [DictationEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? data.dictations : data.dictations.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    @ViewBuilder private var history: some View {
        if data.dictations.isEmpty {
            ContentUnavailableView("No dictations yet", systemImage: "mic",
                                   description: Text("\(holdHint(model.settings)), then let go. Your words are typed where the cursor is."))
        } else if filtered.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List(filtered) { entry in
                HStack(alignment: .top, spacing: Space.md) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(entry.text).textSelection(.enabled)
                        Text(HomePane.caption(entry.app, entry.date)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Space.sm)
                    Button { model.insertAgain(entry.id) } label: { Image(systemName: "text.insert") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("Insert again where the cursor was").accessibilityLabel("Insert again")
                    CopyButton(text: entry.text)
                }
                .padding(.vertical, Space.sm)
                .contextMenu {
                    Button("Insert again") { model.insertAgain(entry.id) }
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.text, forType: .string) }
                    Divider()
                    Button("Delete", role: .destructive) { model.deleteDictation(entry.id, undoManager: undoManager) }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private var vocabulary: some View {
        Form {
            Section {
                Toggle("Remove filler words (um, uh, er)", isOn: $model.settings.removeFillers)
                Toggle("Polish with Apple Intelligence", isOn: $model.settings.polishWithAppleIntelligence)
            } header: {
                Text("Clean-up")
            } footer: {
                Text("Polish fixes punctuation and grammar on this Mac. It is off unless you turn it on.").foregroundStyle(.secondary)
            }
            VocabularySection(dictation: model.dictation, revision: model.wordListsRevision)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

/// The vocabulary editor with the suggestions learnt from corrections (V-G) listed under it.
private struct VocabularySection: View {
    @ObservedObject var dictation: DictationController
    /// `AppModel.wordListsRevision`: the control socket changed a word list.
    let revision: Int

    var body: some View {
        Section {
            // Rebuilt when a suggestion is added or `talkread vocabulary-set` writes, so the editor re-reads vocabulary.json.
            WordMapEditor(url: Paths.vocabulary, keyPrompt: "Heard as", valuePrompt: "Type instead")
                .id([dictation.suggestions.count, revision])
        } header: {
            Text("Vocabulary")
        } footer: {
            Text("Names and terms the recogniser gets wrong, and what to type instead. Type the same word in both columns to teach its spelling.")
                .foregroundStyle(.secondary)
        }
        if !dictation.suggestions.isEmpty {
            Section("Suggestions from your corrections") {
                ForEach(dictation.suggestions, id: \.self) { c in
                    HStack(spacing: Space.md) {
                        Text(c.heard)
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                        Text(c.typed)
                        Spacer()
                        Button("Add") {
                            do { try dictation.acceptSuggestion(c) }
                            catch let error as AppError { MiniPlayer.shared.flash(error.message) }
                            catch { MiniPlayer.shared.flash(error.localizedDescription) }
                        }
                        Button("Dismiss") { dictation.dismissSuggestion(c) }
                    }
                }
            }
        }
    }
}

