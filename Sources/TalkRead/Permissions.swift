// Permission status (Accessibility, Microphone, Screen Recording) and one-shot requests that never loop a prompt.
import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics

extension Permissions {
    static func current() -> Permissions {
        Permissions(accessibility: AXIsProcessTrusted(),
                    microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                    screenRecording: CGPreflightScreenCaptureAccess())
    }
}

/// The system prompt is shown at most once per launch for each permission; after that the matching
/// Privacy pane of System Settings opens instead.
@MainActor enum PermissionRequests {
    private static var prompted: Set<PermissionKind> = []

    static func request(_ p: PermissionKind, then refresh: @escaping @MainActor () -> Void) {
        let firstAsk = prompted.insert(p).inserted
        switch p {
        case .accessibility:
            if firstAsk {
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            } else {
                openPane("Privacy_Accessibility")
            }
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { _ in Task { @MainActor in refresh() } }
            case .authorized: break
            default: openPane("Privacy_Microphone")   // denied or restricted: only System Settings can change it
            }
        case .screenRecording:
            // OCRLocator holds the once-per-launch request, shared with the first OCR need.
            if firstAsk { _ = OCRLocator.hasAccess(requestOnce: true) } else { openPane("Privacy_ScreenCapture") }
        }
        refresh()
    }

    private static func openPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
