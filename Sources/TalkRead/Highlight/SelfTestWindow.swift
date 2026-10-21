// Headless host window (NSTextView, WKWebView, PDFView) for `--selftest-window`. Stub; owned by WP4.
import Foundation

enum SelfTestWindow {
    static func run() -> Int32 {
        FileHandle.standardError.write(Data("--selftest-window: not implemented yet (WP4)\n".utf8))
        return 2
    }
}
