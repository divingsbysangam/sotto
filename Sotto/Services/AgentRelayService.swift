import Foundation
import os

/// L6: Sotto's side of the coding-agent voice relay (see AgentRelay for the file protocol and
/// SottoCLI/AgentHook.swift for the hook). Opt-in: while it's off there is no `enabled` file and
/// every hook exits at once. Sotto only ever writes reply text the user dictated; it never
/// answers permission prompts and never writes allow rules.
final class AgentRelayService {
    static let shared = AgentRelayService()

    private static let logger = Logger(subsystem: "com.divingsbysangam.sotto", category: "AgentRelay")

    /// Called on the main thread for each new request from a hook.
    var onRequest: ((AgentRelay.Request) -> Void)?

    private var scanTimer: Timer?
    private var aliveTimer: Timer?
    private var seen = Set<String>()

    private(set) var isRunning = false

    /// Starts or stops to match the setting. Safe to call repeatedly.
    func sync() {
        let settings = AppSettings.shared
        if settings.agentRelayEnabled {
            start(timeout: settings.agentRelayTimeout)
        } else {
            stop()
        }
    }

    private func start(timeout: TimeInterval) {
        do {
            let data = try JSONEncoder().encode(AgentRelay.Settings(replyTimeout: timeout))
            try AgentRelay.write(data, to: AgentRelay.enabledFile)
        } catch {
            Self.logger.error("agent relay couldn't start: \(error.localizedDescription, privacy: .public)")
            return
        }
        touchAlive()
        guard !isRunning else { return }
        isRunning = true
        let alive = Timer(timeInterval: AgentRelay.aliveInterval, repeats: true) { [weak self] _ in self?.touchAlive() }
        RunLoop.main.add(alive, forMode: .common)
        aliveTimer = alive
        let scan = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.scan() }
        scan.tolerance = 0.2
        RunLoop.main.add(scan, forMode: .common)
        scanTimer = scan
        Self.logger.notice("agent relay on timeout=\(Int(timeout), privacy: .public)s")
    }

    /// The kill switch: removes `enabled` (waiting hooks give up), `alive`, and pending requests.
    func stop() {
        scanTimer?.invalidate()
        aliveTimer?.invalidate()
        scanTimer = nil
        aliveTimer = nil
        let fm = FileManager.default
        try? fm.removeItem(at: AgentRelay.enabledFile)
        try? fm.removeItem(at: AgentRelay.aliveFile)
        for file in (try? fm.contentsOfDirectory(at: AgentRelay.directory, includingPropertiesForKeys: nil)) ?? []
        where file.lastPathComponent.hasSuffix(".request.json") || file.lastPathComponent.hasSuffix(".reply.json") {
            try? fm.removeItem(at: file)
        }
        if isRunning { Self.logger.notice("agent relay off") }
        isRunning = false
        seen.removeAll()
    }

    /// Sends the dictated reply (nil = skip, the agent just stops).
    func reply(to request: AgentRelay.Request, text: String?) {
        guard isRunning, FileManager.default.fileExists(atPath: AgentRelay.requestFile(request.id).path) else {
            Self.logger.notice("reply dropped: the agent stopped waiting")
            return
        }
        guard let data = try? JSONEncoder().encode(AgentRelay.Reply(text: text)) else { return }
        try? AgentRelay.write(data, to: AgentRelay.replyFile(request.id))
        Self.logger.notice("reply sent agent=\(request.agent.rawValue, privacy: .public) chars=\(text?.count ?? 0, privacy: .public)")
    }

    /// Still waiting for a reply.
    func isWaiting(_ request: AgentRelay.Request) -> Bool {
        isRunning && Date() < request.expiresAt
            && FileManager.default.fileExists(atPath: AgentRelay.requestFile(request.id).path)
    }

    private func touchAlive() {
        let fm = FileManager.default
        if fm.fileExists(atPath: AgentRelay.aliveFile.path) {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: AgentRelay.aliveFile.path)
        } else {
            try? AgentRelay.write(Data(), to: AgentRelay.aliveFile)
        }
    }

    private func scan() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: AgentRelay.directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasSuffix(".request.json") {
            let id = String(file.lastPathComponent.dropLast(".request.json".count))
            guard !seen.contains(id),
                  let data = try? Data(contentsOf: file),
                  let request = try? AgentRelay.decoder.decode(AgentRelay.Request.self, from: data) else { continue }
            seen.insert(id)
            // A hook that crashed leaves its request behind; drop it once it can't be answered.
            if Date() > request.expiresAt.addingTimeInterval(60) {
                try? fm.removeItem(at: file)
                continue
            }
            if Date() < request.expiresAt {
                Self.logger.notice("request agent=\(request.agent.rawValue, privacy: .public) event=\(request.event.rawValue, privacy: .public)")
                onRequest?(request)
            }
            // Notifications don't wait for anything.
            if request.event == .notification { try? fm.removeItem(at: file) }
        }
    }

    // MARK: - Hook setup

    /// The installed app's helper (Contents/Helpers/sotto).
    static func hookCommand(agent: AgentRelay.Agent, event: AgentRelay.Event) -> String {
        let tool = CommandLineToolInstaller.bundledTool.path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(tool)' agent-hook --agent \(agent.rawValue) --event \(event.rawValue)"
    }

    /// Claude Code: Stop (spoken follow-ups) and Notification (attention only). Its hook timeout
    /// is set a little above Sotto's reply timeout.
    static func claudeHooks(timeout: TimeInterval) -> [String: Any] {
        func entry(_ event: AgentRelay.Event, seconds: Int) -> [[String: Any]] {
            [["hooks": [["type": "command", "command": hookCommand(agent: .claude, event: event), "timeout": seconds]]]]
        }
        return ["Stop": entry(.stop, seconds: Int(timeout) + 30), "Notification": entry(.notification, seconds: 10)]
    }

    static func cursorHooks() -> [String: Any] {
        ["stop": [["command": hookCommand(agent: .cursor, event: .stop)]]]
    }

    static func snippet(_ hooks: [String: Any], cursor: Bool) -> String {
        let object: [String: Any] = cursor ? ["version": 1, "hooks": hooks] : ["hooks": hooks]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static var claudeSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static var cursorHooksURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor/hooks.json")
    }

    enum SetupError: LocalizedError {
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let path): return "\(path) isn't valid JSON, so it wasn't changed."
            }
        }
    }

    /// Adds Sotto's hooks to a settings file: replaces earlier Sotto entries, keeps everything
    /// else (other hooks, permissions, all other keys) as is, and backs the file up first.
    /// Returns the backup's location, if there was a file.
    @discardableResult
    static func install(_ hooks: [String: Any], into url: URL, cursor: Bool) throws -> URL? {
        let fm = FileManager.default
        var root: [String: Any] = [:]
        var backup: URL?
        if fm.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            if !data.isEmpty {
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw SetupError.unreadable(url.path)
                }
                root = object
            }
            let stamp = Int(Date().timeIntervalSince1970)
            let copy = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).sotto-backup-\(stamp)")
            try fm.copyItem(at: url, to: copy)
            backup = copy
        } else {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        root = merged(root, hooks: hooks, cursor: cursor)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
        logger.notice("installed agent hooks into \(url.lastPathComponent, privacy: .public)")
        return backup
    }

    /// Pure merge (tested): each event's list keeps non-Sotto entries and gets Sotto's appended.
    static func merged(_ root: [String: Any], hooks: [String: Any], cursor: Bool) -> [String: Any] {
        var root = root
        var existing = root["hooks"] as? [String: Any] ?? [:]
        for (event, value) in hooks {
            let others = (existing[event] as? [Any] ?? []).filter { !mentionsSotto($0) }
            existing[event] = others + (value as? [Any] ?? [])
        }
        root["hooks"] = existing
        if cursor, root["version"] == nil { root["version"] = 1 }
        return root
    }

    private static func mentionsSotto(_ entry: Any) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: entry) else { return false }
        return String(decoding: data, as: UTF8.self).contains("agent-hook --agent")
    }
}
