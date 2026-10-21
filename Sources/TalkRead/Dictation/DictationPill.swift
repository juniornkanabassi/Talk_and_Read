// Non-activating panel near the bottom centre: level meter, state, Esc to cancel. Stub; owned by WP5.
import AppKit
import SwiftUI

struct DictationPillView: View {
    @ObservedObject var dictation: DictationController
    var body: some View { Text("Dictation") }   // WP5
}
