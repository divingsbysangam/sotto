import AppKit
import os

/// L11: file names of the project open in a code editor, so spoken names can be written exactly
/// ("app state dot swift" → `AppState.swift`). The project folder comes from the editor window
/// (its open document, or the folder in its title); only file names are indexed, locally, and
/// a handful of projects are kept in memory.
final class WorkspaceIndexService {
    static let shared = WorkspaceIndexService()

    private static let logger = Logger(subsystem: "com.divingsbysangam.sotto", category: "WorkspaceIndex")

    /// Editors whose windows expose the open file (AXDocument) or the project in their title.
    /// The value is the editor's Application Support folder, for its recently opened list.
    static let editors: [String: String?] = [
        "com.apple.dt.Xcode": nil,
        "com.microsoft.VSCode": "Code",
        "com.microsoft.VSCodeInsiders": "Code - Insiders",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.exafunction.windsurf": "Windsurf",
        "com.vscodium": "VSCodium",
    ]

    static let maxFiles = 20_000
    static let maxDepth = 12
    static let maxProjects = 5
    static let staleAfter: TimeInterval = 10 * 60
    private static let skippedFolders: Set<String> = [
        ".git", "node_modules", "build", "Build", "DerivedData", ".build", "Pods", "dist", "vendor",
        ".next", ".venv", "venv", "__pycache__", "target", "out", ".gradle", "Carthage", ".swiftpm"
    ]
    private static let rootMarkers = [".git", "Package.swift", "package.json", "Cargo.toml", "go.mod", "pyproject.toml"]

    private struct Project {
        let task: Task<DictationTextRules.FileNameIndex, Never>
        let builtAt: Date
        var usedAt: Date
    }

    private var projects: [URL: Project] = [:]
    /// The project for the recording in progress.
    private var current: URL?

    static func isEditor(_ app: NSRunningApplication?) -> Bool {
        app?.bundleIdentifier.map { editors.keys.contains($0) } ?? false
    }

    /// At recording start: finds the editor's project and starts indexing it if needed, so the
    /// names are ready by the time the dictation is transcribed.
    @MainActor
    func prepare(for app: NSRunningApplication?, windowTitle: String?) {
        current = nil
        guard AppSettings.shared.resolveFileNamesInEditors, let app, Self.isEditor(app),
              let root = Self.projectRoot(app: app, windowTitle: windowTitle), Self.isIndexable(root) else { return }
        current = root
        if var project = projects[root], Date().timeIntervalSince(project.builtAt) < Self.staleAfter {
            project.usedAt = Date()
            projects[root] = project
            return
        }
        let task = Task.detached(priority: .utility) { Self.buildIndex(root) }
        projects[root] = Project(task: task, builtAt: Date(), usedAt: Date())
        if projects.count > Self.maxProjects,
           let oldest = projects.min(by: { $0.value.usedAt < $1.value.usedAt })?.key {
            projects.removeValue(forKey: oldest)
        }
    }

    /// The index for the current recording's project, if it's ready within `wait` seconds.
    @MainActor
    func currentIndex(wait: TimeInterval = 0.5) async -> DictationTextRules.FileNameIndex? {
        guard let root = current, let task = projects[root]?.task else { return nil }
        return try? await withTimeout(seconds: wait, operation: "Workspace index") { await task.value }
    }

    /// Drops every cached project (Settings › Refresh).
    @MainActor
    func refresh() {
        projects.removeAll()
        current = nil
    }

    // MARK: - Project folder

    /// Never the home folder or the disk root (a loose file there isn't a project).
    static func isIndexable(_ root: URL) -> Bool {
        let path = root.standardizedFileURL.path
        return path != "/" && path != FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
            && path != "/Users"
    }

    static func projectRoot(app: NSRunningApplication, windowTitle: String?) -> URL? {
        if let document = focusedWindowDocument(pid: app.processIdentifier) {
            return enclosingProject(of: document)
        }
        // VS Code-style title: "file — folder — App" (or "folder — App").
        guard let title = windowTitle, let support = app.bundleIdentifier.flatMap({ editors[$0] }) ?? nil else { return nil }
        let parts = title.components(separatedBy: " — ").map { $0.trimmingCharacters(in: .whitespaces) }
        let candidates = parts.count >= 3 ? [parts[parts.count - 2]] : parts.prefix(1).map { $0 }
        for folderName in candidates {
            if let url = recentFolder(named: folderName, editorSupportFolder: support) { return url }
        }
        return nil
    }

    /// The focused window's open document (Xcode and VS Code-based editors set it).
    private static func focusedWindowDocument(pid: pid_t) -> URL? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var windowValue: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let window = windowValue, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var documentValue: AnyObject?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXDocumentAttribute as CFString, &documentValue) == .success,
              let document = documentValue as? String, let url = URL(string: document), url.isFileURL else { return nil }
        return url
    }

    /// Walks up from a file to the folder that looks like the project root.
    static func enclosingProject(of file: URL) -> URL? {
        let fm = FileManager.default
        var folder = file.hasDirectoryPath ? file : file.deletingLastPathComponent()
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        var xcodeProjectFolder: URL?
        while folder.path.count > 1, folder.standardizedFileURL.path != home {
            if rootMarkers.contains(where: { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }) {
                return folder
            }
            if xcodeProjectFolder == nil,
               let items = try? fm.contentsOfDirectory(atPath: folder.path),
               items.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
                xcodeProjectFolder = folder
            }
            folder.deleteLastPathComponent()
        }
        return xcodeProjectFolder ?? file.deletingLastPathComponent()
    }

    /// A folder named `name` from the editor's recently opened list.
    private static func recentFolder(named name: String, editorSupportFolder: String) -> URL? {
        let storage = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(editorSupportFolder)/User/globalStorage/storage.json")
        guard let text = try? String(contentsOf: storage, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: "\"(file://[^\"]+)\"") else { return nil }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = URL(string: ns.substring(with: match.range(at: 1))), url.isFileURL,
                  url.lastPathComponent == name,
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            return url
        }
        return nil
    }

    // MARK: - Index

    /// File names under `root` (bounded), as a ready-to-use spoken-name index.
    static func buildIndex(_ root: URL) -> DictationTextRules.FileNameIndex {
        let start = Date()
        var names = Set<String>()
        let fm = FileManager.default
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants]) {
            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDirectory {
                    if skippedFolders.contains(name) || name.hasPrefix(".") || enumerator.level >= maxDepth {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                names.insert(name)
                if names.count >= maxFiles { break }
            }
        }
        let index = DictationTextRules.FileNameIndex(names: Array(names))
        logger.notice("indexed files=\(names.count, privacy: .public) seconds=\(Date().timeIntervalSince(start), format: .fixed(precision: 2), privacy: .public)")
        return index
    }
}
