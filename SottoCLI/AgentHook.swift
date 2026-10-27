import Foundation

/// L6: `sotto agent-hook --agent claude|cursor --event stop|notification`, run by a coding agent's
/// hook with its event JSON on stdin.
///
/// - Relay off (no `enabled` file) or Sotto not running: exits at once with no output, so the
///   agent carries on as if there were no hook.
/// - notification: hands the text to Sotto to show, then exits (never answers anything).
/// - stop: asks Sotto, then waits up to the reply timeout. A spoken reply is printed in the
///   agent's format so it continues with it; a skip or timeout prints nothing and the agent stops
///   (the terminal is always the fallback).
/// It never prints permission decisions and never writes the agent's settings.
enum AgentHook {
    static func run(_ options: Options) -> Int32 {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let agent = AgentRelay.Agent(rawValue: options.flags["--agent"] ?? "claude"),
              let event = AgentRelay.Event(rawValue: options.flags["--event"] ?? "stop") else {
            FileHandle.standardError.write(Data("sotto agent-hook: --agent claude|cursor, --event stop|notification\n".utf8))
            return 0  // never break the agent over a bad flag
        }
        guard AgentRelay.isEnabled, AgentRelay.isSottoAlive else { return 0 }
        let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]

        // Cursor reports aborted/errored turns too: only a finished turn asks for a follow-up.
        if agent == .cursor, event == .stop, let status = json["status"] as? String, status != "completed" {
            return 0
        }

        let timeout = TimeInterval(options.flags["--timeout"].flatMap(Double.init)
            ?? AgentRelay.settings?.replyTimeout ?? AgentRelay.defaultReplyTimeout)
        let id = UUID().uuidString
        let request = AgentRelay.Request(
            id: id,
            agent: agent,
            event: event,
            project: projectName(json),
            message: AgentRelay.trimmedMessage(message(json, agent: agent, event: event)),
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(event == .stop ? timeout : 30)
        )
        guard let data = try? AgentRelay.encoder.encode(request),
              (try? AgentRelay.write(data, to: AgentRelay.requestFile(id))) != nil else { return 0 }
        guard event == .stop else { return 0 }

        let reply = waitForReply(id, until: request.expiresAt)
        try? FileManager.default.removeItem(at: AgentRelay.requestFile(id))
        try? FileManager.default.removeItem(at: AgentRelay.replyFile(id))
        guard let text = reply?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return 0 }

        let output: [String: Any] = agent == .claude
            ? ["decision": "block", "reason": text]  // Claude Code: continue with this instruction
            : ["followup_message": text]            // Cursor: submit it as the next message
        if let out = try? JSONSerialization.data(withJSONObject: output) {
            FileHandle.standardOutput.write(out)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        return 0
    }

    /// Polls for Sotto's reply; gives up when the relay is switched off or Sotto quits.
    private static func waitForReply(_ id: String, until deadline: Date) -> AgentRelay.Reply? {
        let replyURL = AgentRelay.replyFile(id)
        while Date() < deadline {
            if let data = try? Data(contentsOf: replyURL),
               let reply = try? AgentRelay.decoder.decode(AgentRelay.Reply.self, from: data) {
                return reply
            }
            if !AgentRelay.isEnabled || !AgentRelay.isSottoAlive { return nil }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return nil
    }

    private static func projectName(_ json: [String: Any]) -> String {
        let path = (json["cwd"] as? String) ?? (json["workspace_roots"] as? [String])?.first ?? FileManager.default.currentDirectoryPath
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? "project" : name
    }

    private static func message(_ json: [String: Any], agent: AgentRelay.Agent, event: AgentRelay.Event) -> String {
        if event == .notification {
            return json["message"] as? String ?? "\(agent.displayName) needs your attention"
        }
        if let path = json["transcript_path"] as? String, let last = lastAssistantText(transcript: path) {
            return last
        }
        return ""
    }

    /// Claude Code's transcript is JSONL; the last assistant text is near the end, so only the
    /// last 256 KB are read.
    static func lastAssistantText(transcript path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: (path as NSString).expandingTildeInPath) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > 262_144 ? size - 262_144 : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any] else { continue }
            if let content = message["content"] as? [[String: Any]] {
                let texts = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                if !texts.isEmpty { return texts.joined(separator: "\n") }
            } else if let content = message["content"] as? String, !content.isEmpty {
                return content
            }
        }
        return nil
    }
}
