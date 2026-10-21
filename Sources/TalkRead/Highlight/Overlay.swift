// Click-through panels per screen: word box and sentence tint, ported from ReadAlong. Stub; owned by WP4.
import AppKit
import Foundation

@MainActor final class Overlay {
    struct Style {
        var wordColor: NSColor = NSColor(srgbRed: 1, green: 0.824, blue: 0.122, alpha: 1)   // #FFD21F
        var sentenceColor: NSColor = NSColor(srgbRed: 1, green: 0.824, blue: 0.122, alpha: 0.35)
    }
}
