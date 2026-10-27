import Foundation
import os

/// Upgrade-only compatibility for the retired meeting feature. Run before decoding history;
/// never decode an old meeting as a current output method. Repeated runs retry failed work.
enum LegacyMeetingCleanup {
    private static let logger = Logger(subsystem: "com.sotto.app", category: "LegacyMeetingCleanup")

    /// Preserve every field of surviving entries, including fields unknown to this app version.
    static func historyDataWithoutMeetings(_ data: Data) throws -> Data {
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CocoaError(.coderReadCorrupt)
        }
        let kept = entries.filter { ($0["outputMethod"] as? String) != "meeting" }
        guard kept.count != entries.count else { return data }
        return try JSONSerialization.data(withJSONObject: kept, options: [.sortedKeys])
    }

    @discardableResult
    static func run(
        directory: URL,
        defaults: UserDefaults,
        write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) },
        remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) -> Bool {
        var succeeded = true
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            for file in files where isHistoryFile(file.lastPathComponent) {
                do {
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    let original = try Data(contentsOf: file)
                    let filtered = try historyDataWithoutMeetings(original)
                    if filtered != original { try write(filtered, file) }
                } catch {
                    succeeded = false
                    logger.error("Legacy history cleanup failed; file preserved for retry")
                }
            }
        } catch {
            succeeded = false
            logger.error("Legacy history cleanup could not list files; will retry")
        }
        for name in ["Meetings", "SpeakerKit"] {
            let url = directory.appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do { try remove(url) } catch {
                succeeded = false
                logger.error("Legacy meeting files could not be removed; will retry")
            }
        }
        for key in ["meetingSystemAudio", "meetingDetection", "meetingSpeakerCount"] {
            defaults.removeObject(forKey: key)
        }
        return succeeded
    }

    private static func isHistoryFile(_ name: String) -> Bool {
        name.range(
            of: #"^history\.json(?:\.bak)?$|^history-[0-9]+\.json\.bak$|^history-unreadable-[0-9]+\.json$"#,
            options: .regularExpression
        ) != nil
    }
}
