// Selection capture (AX first, clipboard fallback with full pasteboard restore) and the Capture value. Stub; owned by WP4.
import ApplicationServices
import Foundation

struct Capture {
    enum Source { case accessibility, copied, cursor, clipboard, ocr, provided }
    let text: String
    let pid: pid_t
    let element: AXUIElement?
    let window: AXUIElement?
    let selectionStart: Int?
    let source: Source
}

enum TextCapture {
    @MainActor static func captureSelection() async -> Capture? { fatalError("WP4") }
}
