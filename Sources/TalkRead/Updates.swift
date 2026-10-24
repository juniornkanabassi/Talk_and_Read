// Self-updating with Sparkle 2 (PLAN 0.7.0). Sparkle's standard updater and user driver do the work: they check on
// launch and daily (Info.plist), show the release notes and install only after the user agrees. Also the headless
// `--selftest-update` proof, which drives the real updater with a user driver that never shows a window.
import AppKit
import Sparkle
import TalkReadCore

@MainActor enum Updates {
    /// Started by the AppDelegate; nil in the self-tests and snapshots.
    static var controller: SPUStandardUpdaterController?

    static var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    /// "Check for Updates…" in both menus and `talkread update-check`: Sparkle's own user-initiated check.
    static func check() throws {
        guard let controller else { throw AppError(code: "unavailable", message: "The updater is not running in this copy of Talk & Read.") }
        guard controller.updater.canCheckForUpdates else {
            throw AppError(code: "busy", message: "An update check or install is already in progress.")
        }
        controller.checkForUpdates(nil)
    }
}

/// `--selftest-update <feed URL>`: checks the given feed instead of SUFeedURL, accepts the update it finds, and exits
/// once Sparkle's installer has downloaded, extracted and verified it (EdDSA and code signature). Sparkle then installs
/// it into this bundle as the process quits, with no relaunch and no progress window. Runs only on a test copy with its
/// own bundle id, so Junior's installed app and its defaults are never touched.
@MainActor enum UpdateSelfTest {
    static func run(feed: String) async -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        let bundle = Bundle.main
        guard let id = bundle.bundleIdentifier, id != "com.juniornkanabassi.TalkAndRead" else {
            print("selftest-update: refused: run it on a test copy with its own bundle id (it updates the bundle it runs from)")
            return 2
        }
        let version = { (key: String) in bundle.object(forInfoDictionaryKey: key) as? String ?? "?" }
        print("selftest-update: \(bundle.bundlePath) is \(version("CFBundleShortVersionString")) (build \(version("CFBundleVersion"))); feed \(feed)")
        let driver = HeadlessDriver(), delegate = FeedOverride(feed: feed)
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: delegate)
        do { try updater.start() } catch {
            print("selftest-update: FAIL the updater did not start: \(error.localizedDescription)")
            return 1
        }
        updater.checkForUpdates()
        let deadline = Date().addingTimeInterval(120)
        while driver.outcome == nil, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        print("selftest-update: \(driver.outcome ?? "FAIL no answer from Sparkle within 120 s")")
        return driver.outcome?.hasPrefix("PASS") == true ? 0 : 1
    }

    private final class FeedOverride: NSObject, SPUUpdaterDelegate {
        let feed: String
        init(feed: String) { self.feed = feed }
        func feedURLString(for updater: SPUUpdater) -> String? { feed }
    }

    /// Prints each step; agrees to download; stops at "ready to install" so the install happens as the process quits.
    private final class HeadlessDriver: NSObject, SPUUserDriver {
        var outcome: String?
        private var bytes: UInt64 = 0

        func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
            reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
        }
        func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { print("update: checking") }
        func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
            print("update: found \(item.displayVersionString) (build \(item.versionString)), \(item.contentLength) bytes, minimum macOS \(item.minimumSystemVersion ?? "-"), "
                  + "notes \(item.itemDescription.map { "inline, \($0.count) characters" } ?? item.releaseNotesURL?.absoluteString ?? "none")")
            reply(.install)
        }
        func showUpdateReleaseNotes(with downloadData: SPUDownloadData) { print("update: release notes downloaded, \(downloadData.data.count) bytes") }
        func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { print("update: release notes failed: \(error.localizedDescription)") }
        func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
            outcome = "FAIL no update found: \(error.localizedDescription)"
            acknowledgement()
        }
        func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
            outcome = "FAIL updater error: \(error.localizedDescription)"
            acknowledgement()
        }
        func showDownloadInitiated(cancellation: @escaping () -> Void) { print("update: downloading") }
        func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
        func showDownloadDidReceiveData(ofLength length: UInt64) { bytes += length }
        func showDownloadDidStartExtractingUpdate() { print("update: downloaded \(bytes) bytes; extracting and verifying") }
        func showExtractionReceivedProgress(_ progress: Double) {}
        func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
            outcome = "PASS ready to install: downloaded, extracted and verified by Sparkle's installer, which installs it as this process quits (no relaunch)"
        }
        func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}
        func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
        func dismissUpdateInstallation() { if outcome == nil { outcome = "FAIL the update was dismissed before it was ready" } }
    }
}
