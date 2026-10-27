import Foundation
import os

/// L9: App Modes as shareable JSON files. Exports are id-free and versioned; imports are data only
/// (no scripts or anything executable), validated, previewed, and deduplicated by name.
enum ModeTransferService {
    private static let logger = Logger(subsystem: "com.divingsbysangam.sotto", category: "ModeTransfer")

    static let fileKind = "appModes"
    static let fileVersion = 1
    static let maxPromptLength = 8_000
    static let maxMatches = 100

    /// One mode as written to disk. Everything but identity: ids and built-in flags are local.
    struct ExportedMode: Codable, Equatable {
        struct Example: Codable, Equatable { var input: String; var output: String }

        var name: String
        var prompt: String = ""
        var overrideDefaults: Bool = false
        var matchedApps: [String] = []
        var matchedWebsites: [String] = []
        var catalogCategories: [String] = []
        var examples: [Example] = []
        var sendAfterPaste: Bool = false
        var sendKey: String = AppMode.SendKey.returnKey.rawValue
        var raw: Bool = false
        var translateToEnglish: Bool = false
        var enabled: Bool = true

        init(_ mode: AppMode) {
            name = mode.displayName
            prompt = mode.prompt
            overrideDefaults = mode.overrideDefaults
            matchedApps = mode.matchedApps
            matchedWebsites = mode.matchedWebsites
            catalogCategories = mode.catalogCategories
            examples = mode.promptExamples.map { Example(input: $0.input, output: $0.output) }
            sendAfterPaste = mode.sendAfterPaste
            sendKey = mode.sendKey.rawValue
            raw = mode.skipsCleanup
            translateToEnglish = mode.translateToEnglish
            enabled = mode.isEnabled
        }

        // Every field but the name is optional so hand-written files import.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
            overrideDefaults = try c.decodeIfPresent(Bool.self, forKey: .overrideDefaults) ?? false
            matchedApps = try c.decodeIfPresent([String].self, forKey: .matchedApps) ?? []
            matchedWebsites = try c.decodeIfPresent([String].self, forKey: .matchedWebsites) ?? []
            catalogCategories = try c.decodeIfPresent([String].self, forKey: .catalogCategories) ?? []
            examples = try c.decodeIfPresent([Example].self, forKey: .examples) ?? []
            sendAfterPaste = try c.decodeIfPresent(Bool.self, forKey: .sendAfterPaste) ?? false
            sendKey = try c.decodeIfPresent(String.self, forKey: .sendKey) ?? AppMode.SendKey.returnKey.rawValue
            raw = try c.decodeIfPresent(Bool.self, forKey: .raw) ?? false
            translateToEnglish = try c.decodeIfPresent(Bool.self, forKey: .translateToEnglish) ?? false
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        }

        /// A new local mode with this content (fresh id, never built-in).
        func makeMode(id: UUID = UUID(), name: String? = nil) -> AppMode {
            AppMode(
                id: id,
                displayName: name ?? self.name,
                matchedApps: matchedApps,
                matchedWebsites: matchedWebsites,
                prompt: prompt,
                isEnabled: enabled,
                overrideDefaults: overrideDefaults,
                isBuiltIn: false,
                sendAfterPaste: sendAfterPaste,
                sendKey: AppMode.SendKey(rawValue: sendKey) ?? .returnKey,
                skipsCleanup: raw,
                requiresAppleIntelligence: false,
                promptExamples: examples.map { AppMode.PromptExample(input: $0.input, output: $0.output) },
                catalogCategories: catalogCategories.filter { AppCatalog.Category(rawValue: $0) != nil },
                translateToEnglish: translateToEnglish
            )
        }
    }

    struct File: Codable {
        var sotto: Int
        var kind: String
        var modes: [ExportedMode]
    }

    enum TransferError: LocalizedError {
        case unreadable
        case wrongKind
        case newerVersion(Int)
        case invalid(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .unreadable: return "This isn't a Sotto App Modes file."
            case .wrongKind: return "This Sotto file doesn't contain App Modes."
            case .newerVersion(let v): return "This file was made by a newer Sotto (format \(v)). Update Sotto to import it."
            case .invalid(let why): return "The file has an invalid mode: \(why)"
            case .empty: return "The file has no modes."
            }
        }
    }

    // MARK: - Export

    static func encode(_ modes: [AppMode]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(File(sotto: fileVersion, kind: fileKind, modes: modes.map(ExportedMode.init)))
    }

    static func export(_ modes: [AppMode], to url: URL) throws {
        try encode(modes).write(to: url, options: .atomic)
        logger.notice("exported \(modes.count, privacy: .public) mode(s)")
    }

    /// "Code Mode.json" for one mode, "Sotto App Modes.json" for several.
    static func suggestedFileName(for modes: [AppMode]) -> String {
        guard modes.count == 1, let name = modes.first?.displayName else { return "Sotto App Modes.json" }
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        return "\(safe) Mode.json"
    }

    // MARK: - Import

    /// Parses and validates a file. Unknown keys are ignored.
    static func decode(_ data: Data) throws -> [ExportedMode] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TransferError.unreadable
        }
        guard let version = object["sotto"] as? Int else { throw TransferError.unreadable }
        guard object["kind"] as? String == fileKind else { throw TransferError.wrongKind }
        guard version <= fileVersion else { throw TransferError.newerVersion(version) }
        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: data)
        } catch {
            throw TransferError.unreadable
        }
        guard !file.modes.isEmpty else { throw TransferError.empty }
        return try file.modes.map(validated)
    }

    static func load(from url: URL) throws -> [ExportedMode] {
        let modes = try decode(Data(contentsOf: url))
        logger.notice("read \(modes.count, privacy: .public) mode(s) for import")
        return modes
    }

    /// Trims text, rejects blank names and oversized content, keeps at most the usable examples.
    static func validated(_ mode: ExportedMode) throws -> ExportedMode {
        var mode = mode
        func clean(_ list: [String]) -> [String] {
            var seen = Set<String>()
            return list
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        }
        mode.name = mode.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mode.name.isEmpty else { throw TransferError.invalid("a mode has no name") }
        guard mode.name.count <= 60 else { throw TransferError.invalid("“\(mode.name.prefix(20))…” has a name over 60 characters") }
        guard mode.prompt.count <= maxPromptLength else {
            throw TransferError.invalid("“\(mode.name)” has instructions over \(maxPromptLength) characters")
        }
        mode.matchedApps = clean(mode.matchedApps)
        mode.matchedWebsites = clean(mode.matchedWebsites)
        mode.catalogCategories = clean(mode.catalogCategories)
        guard mode.matchedApps.count + mode.matchedWebsites.count <= maxMatches else {
            throw TransferError.invalid("“\(mode.name)” matches over \(maxMatches) apps and websites")
        }
        mode.examples = Array(mode.examples
            .filter { !$0.input.trimmingCharacters(in: .whitespaces).isEmpty && !$0.output.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(AppMode.maxPromptExamples))
        return mode
    }

    // MARK: - Preview and apply

    struct PreviewItem: Identifiable {
        enum Status: Equatable {
            /// No mode with this name.
            case new
            /// A custom mode with this name and the same content (unchecked by default).
            case identical
            /// A custom mode with this name: importing replaces its content (keeps its id).
            case replaces(UUID)
            /// A built-in mode has this name: imported as a copy under `name`.
            case copyOfBuiltIn(name: String)
        }

        let id = UUID()
        let mode: ExportedMode
        let status: Status

        var isCheckedByDefault: Bool { status != .identical }
    }

    static func preview(_ incoming: [ExportedMode], against existing: [AppMode]) -> [PreviewItem] {
        var seen = Set<String>()
        var takenNames = Set(existing.map { $0.displayName.lowercased() })
        return incoming.compactMap { mode in
            guard seen.insert(mode.name.lowercased()).inserted else { return nil }  // first wins within a file
            guard let match = existing.first(where: { $0.displayName.caseInsensitiveCompare(mode.name) == .orderedSame }) else {
                return PreviewItem(mode: mode, status: .new)
            }
            if match.isBuiltIn {
                let name = uniqueName("\(mode.name) (imported)", taken: &takenNames)
                return PreviewItem(mode: mode, status: .copyOfBuiltIn(name: name))
            }
            if ExportedMode(match) == mode {
                return PreviewItem(mode: mode, status: .identical)
            }
            return PreviewItem(mode: mode, status: .replaces(match.id))
        }
    }

    /// The modes after importing `items`. New modes go after existing ones so built-ins keep
    /// their matching precedence; a replaced mode keeps its place and id.
    static func apply(_ items: [PreviewItem], to existing: [AppMode]) -> [AppMode] {
        var modes = existing
        for item in items {
            switch item.status {
            case .identical:
                continue
            case .new:
                modes.append(item.mode.makeMode())
            case .replaces(let id):
                if let index = modes.firstIndex(where: { $0.id == id }) {
                    modes[index] = item.mode.makeMode(id: id)
                } else {
                    modes.append(item.mode.makeMode())
                }
            case .copyOfBuiltIn(let name):
                modes.append(item.mode.makeMode(name: name))
            }
        }
        logger.notice("imported \(items.count, privacy: .public) mode(s)")
        return modes
    }

    private static func uniqueName(_ base: String, taken: inout Set<String>) -> String {
        var name = base
        var n = 2
        while taken.contains(name.lowercased()) {
            name = "\(base) \(n)"
            n += 1
        }
        taken.insert(name.lowercased())
        return name
    }
}
