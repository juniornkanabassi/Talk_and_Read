// AF_UNIX control socket: JSON command schema, server and client. Stub; WP2 ports it from ReadAlong's Control.swift.
import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null
}

public struct ControlRequest: Codable, Sendable {
    /// Client UUID, reused on retry; replay key is (caller, id).
    public var id: String
    public var command: String
    public var args: [String: String]
    public var caller: String
    public var force: Bool
    public init(id: String = UUID().uuidString, command: String, args: [String: String] = [:], caller: String = "cli", force: Bool = false) {
        self.id = id; self.command = command; self.args = args; self.caller = caller; self.force = force
    }
}

public struct ControlResponse: Codable, Sendable {
    public var ok: Bool
    public var code: String?
    public var message: String?
    public var data: [String: JSONValue]?
    public init(ok: Bool, code: String? = nil, message: String? = nil, data: [String: JSONValue]? = nil) {
        self.ok = ok; self.code = code; self.message = message; self.data = data
    }
}

public final class ControlServer {
    public init(path: URL, handler: @escaping @Sendable (ControlRequest) async -> ControlResponse) throws {
        fatalError("WP2")
    }
    public func stop() { fatalError("WP2") }
}

public enum ControlClient {
    public static func send(_ r: ControlRequest, to path: URL, timeout: Double) throws -> ControlResponse {
        fatalError("WP2")
    }
}
