// Data root and the files inside it; TALKREAD_HOME overrides the root for tests. Owned by WP2.
import Foundation

public enum Paths {
    public static let dataRoot: URL = {
        if let home = ProcessInfo.processInfo.environment["TALKREAD_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Talk and Read", isDirectory: true)
    }()
    public static var controlSocket: URL { dataRoot.appendingPathComponent("control.sock") }
    public static var settings: URL { dataRoot.appendingPathComponent("settings.json") }
}
