// Self-updating with Sparkle 2 (PLAN 0.7.0). Sparkle's standard updater and user driver do the work: they show the
// release notes and install only after the user agrees. This delegate pins the configuration (the production feed
// whatever the defaults say, no system profile), checks at every launch, keeps a gentle reminder for an update found
// while the app is in the background (it has no Dock icon, so Sparkle's alert could sit unseen behind other windows),
// and records each check's result for `talkread status`. Also the headless `--selftest-update` proofs.
import AppKit
import Combine
import Sparkle
import TalkReadCore

@MainActor final class Updates: NSObject, ObservableObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate, NSMenuItemValidation {
    static let shared = Updates()
    static let feed = "https://juniornkanabassi.com/apps/talkandread/appcast.xml"
    static let productionID = "com.juniornkanabassi.TalkAndRead"

    private var controller: SPUStandardUpdaterController?   // keeps Sparkle's standard user driver alive
    private(set) var updater: SPUUpdater?
    /// The version of a scheduled update Sparkle found in the background; the menu bar menu leads with it.
    @Published private(set) var reminder: String?
    private(set) var checking = false
    private(set) var checkID: String?
    private(set) var result: String?        // "upToDate", "available <version>" or "error <message>"
    private var reservedID: String?         // the id `check()` handed out, taken by the check Sparkle then starts
    /// The `--selftest-update` feed. Never used under the production bundle id.
    var testFeed: String?

    var isEnabled: Bool { updater != nil }
    var canCheck: Bool { updater?.canCheckForUpdates ?? false }

    /// At launch. A build without SUFeedURL (build.sh's ad hoc development build) gets no updater and no menu items.
    func start() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let c = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        controller = c
        // Sparkle's scheduler alone waits out the rest of its 24 h after a relaunch; PLAN says launch and daily.
        if begin(c.updater), c.updater.automaticallyChecksForUpdates { c.updater.checkForUpdatesInBackground() }
    }

    /// No system profile, then start. The self-test passes its own updater (a windowless user driver).
    @discardableResult func begin(_ u: SPUUpdater) -> Bool {
        u.sendsSystemProfile = false
        do { try u.start() } catch {
            Log.write("updater did not start: \(error.localizedDescription)")
            return false
        }
        updater = u
        return true
    }

    /// The menus' "Check for Updates…" and `talkread update-check`. Admission is synchronous on the main actor, so of
    /// two callers one starts the check and the other is told busy with its id. While Sparkle already shows an update
    /// (the reminder's included) this brings that window forward instead of checking again.
    func check() throws -> (started: Bool, checkID: String?) {
        guard let updater else { throw AppError(code: "unavailable", message: "Updates are off in this copy of Talk & Read.") }
        guard !checking, updater.canCheckForUpdates else {
            throw AppError(code: "busy", message: "An update check or install is already in progress.", data: checkID.map { ["checkID": .string($0)] })
        }
        if updater.sessionInProgress {
            updater.checkForUpdates()
            return (false, checkID)
        }
        let id = UUID().uuidString
        (checking, checkID, reservedID, result) = (true, id, id, nil)
        updater.checkForUpdates()
        return (true, id)
    }

    @objc func checkForUpdates(_ sender: Any?) { _ = try? check() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { canCheck }

    func json() -> [String: JSONValue] {
        func s(_ v: String?) -> JSONValue { v.map { .string($0) } ?? .null }
        return ["enabled": .bool(isEnabled), "checking": .bool(checking), "checkID": s(checkID), "result": s(result),
                "lastCheck": s(updater?.lastUpdateCheckDate.map { ISO8601DateFormatter().string(from: $0) }), "reminder": s(reminder)]
    }

    // MARK: SPUUpdaterDelegate

    func feedURLString(for updater: SPUUpdater) -> String? {
        if let testFeed, Bundle.main.bundleIdentifier != Self.productionID { return testFeed }
        return Self.feed
    }

    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        checkID = updateCheck == .updates ? reservedID ?? UUID().uuidString : UUID().uuidString
        (checking, reservedID, result) = (true, nil, nil)   // each check reports only its own outcome
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) { finish("available \(item.displayVersionString)") }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) { finish("upToDate") }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // 1001 no update (reported above), 4007 the user cancelled the install
        if ![1001, 4007].contains((error as NSError).code) { finish("error \(error.localizedDescription)") }
    }

    /// A cycle that ends with no outcome (the user cancelled the check, or the alert was dismissed before one) says so.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        checking = false
        if result == nil { result = "cancelled" }
    }

    private func finish(_ r: String) { (result, checking) = (r, false) }

    // MARK: Gentle reminders (Sparkle's documented pattern for background apps)

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Near launch Sparkle brings its alert forward itself; later, the menu bar menu and the status icon say so instead.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate { reminder = update.displayVersionString }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) { reminder = nil }
    func standardUserDriverWillFinishUpdateSession() { reminder = nil }
}

/// `--selftest-update <feed URL> [--reminder | --sequence <feed that never answers>]`, on a test copy with its own bundle id (it may update the bundle it runs
/// from, and it writes Sparkle's defaults), so Junior's installed app and its defaults are never touched. The feed
/// replaces SUFeedURL. Prints structured lines that `Tools/update-e2e.sh` asserts:
/// - default: two callers send `update-check` through the control path (one starts, one is busy with the same id);
///   a windowless user driver accepts the update and exits once Sparkle's installer has downloaded, extracted and
///   verified it, so Sparkle installs it into this bundle as the process quits, with no relaunch and no window.
/// - `--reminder`: the production start (standard user driver, launch check). The app is neither active nor a
///   background app here, so Sparkle never shows its alert; the test proves the gentle reminder reaches the menu.
/// - `--sequence`: three checks in a row (found and dismissed, cancelled while checking, found again), each with its
///   own checkID and its own result.
@MainActor enum UpdateSelfTest {
    static func run(feed: String, args: [String]) async -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        let bundle = Bundle.main
        guard let id = bundle.bundleIdentifier, id != Updates.productionID else {
            print("selftest-update: refused: run it on a test copy with its own bundle id")
            return 2
        }
        let info = { (key: String) in bundle.object(forInfoDictionaryKey: key) as? String ?? "?" }
        print("selftest-update: \(bundle.bundlePath) is \(info("CFBundleShortVersionString")) (build \(info("CFBundleVersion"))); feed \(feed)")
        let updates = Updates.shared
        updates.testFeed = feed
        if args.contains("--reminder") { return await remind(updates) }
        if let i = args.firstIndex(of: "--sequence"), i + 1 < args.count { return await sequence(updates, bundle, feed: feed, silent: args[i + 1]) }
        return await install(updates, bundle)
    }

    private static func sequence(_ updates: Updates, _ bundle: Bundle, feed: String, silent: String) async -> Int32 {
        let driver = HeadlessDriver()
        driver.dismissFound = true
        guard updates.begin(SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: updates)) else {
            print("selftest-update: FAIL the updater did not start")
            return 1
        }
        var seen: [(id: String?, result: String?)] = []
        for (url, cancel) in [(feed, false), (silent, true), (feed, false)] {
            (updates.testFeed, driver.cancelCheck) = (url, cancel)
            let r = await AppModel.shared.handle(ControlRequest(command: "update-check", caller: "sequence"))
            await wait { !updates.checking && updates.updater?.sessionInProgress == false }
            let id = r.data?["checkID"]?.stringValue
            seen.append((updates.checkID == id ? id : nil, updates.result))
            print("update-sequence: checkID \(id ?? "none") result \(updates.result ?? "null")")
        }
        let results = seen.map { $0.result ?? "null" }
        let pass = Set(seen.compactMap(\.id)).count == 3 && results[0].hasPrefix("available ") && results[1] == "cancelled" && results[2] == results[0]
        print("selftest-update: \(pass ? "PASS three checks, three checkIDs: \(results.joined(separator: ", "))" : "FAIL \(results)")")
        return pass ? 0 : 1
    }

    private static func install(_ updates: Updates, _ bundle: Bundle) async -> Int32 {
        let driver = HeadlessDriver()
        guard updates.begin(SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: updates)) else {
            print("selftest-update: FAIL the updater did not start")
            return 1
        }
        async let a = AppModel.shared.handle(ControlRequest(command: "update-check", caller: "a"))
        async let b = AppModel.shared.handle(ControlRequest(command: "update-check", caller: "b"))
        let both = await [a, b]
        let started = both.filter { $0.ok && $0.data?["started"]?.boolValue == true }, busy = both.filter { $0.code == "busy" }
        let id = started.first?.data?["checkID"]?.stringValue
        let shared = id != nil && busy.first?.data?["checkID"]?.stringValue == id
        print("update-callers: \(started.count) started, \(busy.count) busy, same checkID \(shared)")
        await wait { driver.outcome != nil }
        print("update-status: \(status())")
        print("selftest-update: \(driver.outcome ?? "FAIL no answer from Sparkle within 120 s")")
        return driver.outcome?.hasPrefix("PASS") == true && started.count == 1 && busy.count == 1 && shared ? 0 : 1
    }

    private static func remind(_ updates: Updates) async -> Int32 {
        updates.start()
        guard updates.isEnabled else { print("selftest-update: FAIL the updater did not start"); return 1 }
        await wait { updates.reminder != nil || updates.result?.hasPrefix("error") == true }
        let menu = MenuBarMenu(model: AppModel.shared, openMain: {}, openSettings: {}, openOnboarding: {}).dump()
        print("update-menu: \(menu.first ?? "-") | \(menu.dropFirst().first ?? "-")")
        print("update-status: \(status())")
        let pass = updates.reminder != nil && menu.first == "Update available: \(updates.reminder ?? "")…"
        print("selftest-update: \(pass ? "PASS reminder in the menu bar menu, no alert shown" : "FAIL no reminder")")
        return pass ? 0 : 1
    }

    private static func status() -> String {
        Updates.shared.json().sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.stringValue ?? $0.value.boolValue.map { String($0) } ?? "null")" }.joined(separator: " ")
    }

    private static func wait(_ done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(120)
        while !done(), Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// Prints each step; agrees to download; stops at "ready to install" so the install happens as the process quits.
    private final class HeadlessDriver: NSObject, SPUUserDriver {
        var outcome: String?
        var dismissFound = false, cancelCheck = false
        private var bytes: UInt64 = 0

        /// "4005>4005>3002": the error and its underlying errors, so the e2e test can require Sparkle's own reason.
        private func codes(_ error: Error) -> String {
            var e: NSError? = error as NSError, out: [String] = []
            while let n = e { out.append("\(n.code)"); e = n.userInfo[NSUnderlyingErrorKey] as? NSError }
            return out.joined(separator: ">")
        }

        func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
            reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
        }
        func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
            print("update: checking")
            if cancelCheck { print("update: cancelling the check"); cancellation() }
        }
        func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
            print("update: found \(item.displayVersionString) (build \(item.versionString)), \(item.contentLength) bytes, minimum macOS \(item.minimumSystemVersion ?? "-"), "
                  + "notes \(item.itemDescription.map { "inline, \($0.count) characters" } ?? item.releaseNotesURL?.absoluteString ?? "none")")
            reply(dismissFound ? .dismiss : .install)
        }
        func showUpdateReleaseNotes(with downloadData: SPUDownloadData) { print("update: release notes downloaded, \(downloadData.data.count) bytes") }
        func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { print("update: release notes failed: \(error.localizedDescription)") }
        func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
            let reason = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? Int
            print("update-not-found: code \(codes(error)) reason \(reason.map { String($0) } ?? "-")")
            outcome = "FAIL no update found: \(error.localizedDescription)"
            acknowledgement()
        }
        func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
            print("update-error: codes \(codes(error)) \(error.localizedDescription)")
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
