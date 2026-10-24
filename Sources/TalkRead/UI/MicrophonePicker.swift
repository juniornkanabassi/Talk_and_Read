// The microphone dictation uses: the list follows plugging and unplugging, one picker for Settings and the Dictation page.
// A choice is saved at once and applies from the next recording; a recording in progress is never touched.
import SwiftUI
import TalkReadCore

@MainActor final class MicrophoneList: ObservableObject {
    static let shared = MicrophoneList()
    @Published private(set) var inputs = Microphone.inputs()
    private init() {
        Microphone.observe { Task { @MainActor in MicrophoneList.shared.inputs = Microphone.inputs() } }
    }
}

struct MicrophonePicker: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var list = MicrophoneList.shared

    var body: some View {
        let saved = model.settings.dictationMicrophone
        Picker("Microphone", selection: $model.settings.dictationMicrophone) {
            Text(Microphone.defaultLabel(list.inputs)).tag(String?.none)
            ForEach(list.inputs) { Text($0.name).tag(String?.some($0.uid)) }
            if let saved, !list.inputs.contains(where: { $0.uid == saved }) {   // kept, and used again once it is back
                Text("Not connected (\(Microphone.defaultLabel(list.inputs)) for now)").tag(String?.some(saved))
            }
        }
        .help("Applies from the next dictation")
    }
}
