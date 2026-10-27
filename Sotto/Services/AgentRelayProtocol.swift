import Foundation

/// L6: the files the coding-agent hook (`sotto agent-hook`, in SottoCLI) and the app exchange.
/// Compiled into both targets. Everything lives in one folder only this user can open (0700);
/// each file is 0600.
///
/// - `enabled`: present only while the relay is on in Settings (the kill switch). Holds the
///   reply timeout.
/// - `alive`: touched every few seconds while Sotto runs; the hook gives up at once without it,
///   so an agent never waits on a Sotto that isn't there.
/// - `<id>.request.json`: written by the hook. `<id>.reply.json`: written by Sotto.
enum AgentRelay {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Sotto/AgentRelay", isDirectory: true)
    }

    static var enabledFile: URL { directory.appendingPathComponent("enabled") }
    static var aliveFile: URL { directory.appendingPathComponent("alive") }
    static let aliveInterval: TimeInterval = 5
    /// The hook treats Sotto as gone when `alive` is older than this.
    static let aliveTimeout: TimeInterval = 15
    static let defaultReplyTimeout: TimeInterval = 120
    static let maxMessageChars = 500

    struct Settings: Codable {
        var replyTimeout: TimeInterval
    }

    enum Agent: String, Codable {
        case claude, cursor

        var displayName: String {
            switch self {
            case .claude: return "Claude Code"
            case .cursor: return "Cursor"
            }
        }
    }

    enum Event: String, Codable {
        /// The agent finished its turn: Sotto can send a spoken follow-up.
        case stop
        /// The agent needs attention (e.g. a permission prompt): notify only, never answered by voice.
        case notification
    }

    struct Request: Codable {
        let id: String
        let agent: Agent
        let event: Event
        /// The project folder's name.
        let project: String
        /// The agent's last message (stop) or its notification text, trimmed.
        let message: String
        let createdAt: Date
        /// When the hook stops waiting.
        let expiresAt: Date
    }

    struct Reply: Codable {
        /// Nil = skipped: the agent just stops.
        let text: String?
    }

    static func requestFile(_ id: String) -> URL { directory.appendingPathComponent("\(id).request.json") }
    static func replyFile(_ id: String) -> URL { directory.appendingPathComponent("\(id).reply.json") }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: enabledFile.path) }

    static var settings: Settings? {
        (try? Data(contentsOf: enabledFile)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
    }

    static var isSottoAlive: Bool {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: aliveFile.path))?[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(modified) < aliveTimeout
    }

    /// Creates the folder (0700) if needed and writes `data` readable by this user only.
    static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = url.appendingPathExtension("tmp")
        guard fm.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        _ = try? fm.removeItem(at: url)
        try fm.moveItem(at: temporary, to: url)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Trims to `maxMessageChars`, keeping the end (the agent's closing question is there).
    static func trimmedMessage(_ text: String) -> String {
        let collapsed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maxMessageChars else { return collapsed }
        return "…" + collapsed.suffix(maxMessageChars - 1)
    }
}
