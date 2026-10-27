import Foundation
import os

/// L14: puts the bundled `sotto` tool (Contents/Helpers/sotto) on the PATH as a symlink, so it
/// always runs the installed app's copy. No admin rights: the first writable bin directory wins.
enum CommandLineToolInstaller {
    private static let logger = Logger(subsystem: "com.divingsbysangam.sotto", category: "CLI")

    static var bundledTool: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sotto")
    }

    static var localBin: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
    }

    /// Checked in order; ~/.local/bin is created if needed.
    static var candidateDirectories: [URL] {
        [URL(fileURLWithPath: "/usr/local/bin"), URL(fileURLWithPath: "/opt/homebrew/bin"), localBin]
    }

    /// Where a `sotto` link to this app's tool already is, if anywhere.
    static var installedLink: URL? {
        candidateDirectories
            .map { $0.appendingPathComponent("sotto") }
            .first { link in
                guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return false }
                return destination.hasSuffix("/Contents/Helpers/sotto")
            }
    }

    /// True when `directory` is on the PATH a new Terminal window gets (approximated by
    /// macOS's /etc/paths plus the shells' usual additions).
    static func isOnPath(_ directory: URL) -> Bool {
        if directory.path == "/usr/local/bin" { return true }  // in /etc/paths
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":").contains { String($0) == directory.path }
    }

    enum InstallError: LocalizedError {
        case missingTool
        case noWritableDirectory
        case occupied(String)

        var errorDescription: String? {
            switch self {
            case .missingTool: return "This copy of Sotto doesn't include the command-line tool."
            case .noWritableDirectory: return "No writable folder was found for the command."
            case .occupied(let path): return "\(path) already exists and isn't Sotto's. Remove it first."
            }
        }
    }

    @discardableResult
    static func install() throws -> URL {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: bundledTool.path) else { throw InstallError.missingTool }
        if let existing = installedLink { try? fm.removeItem(at: existing) }
        try? fm.createDirectory(at: localBin, withIntermediateDirectories: true)
        guard let directory = candidateDirectories.first(where: { fm.isWritableFile(atPath: $0.path) }) else {
            throw InstallError.noWritableDirectory
        }
        let link = directory.appendingPathComponent("sotto")
        if (try? fm.attributesOfItem(atPath: link.path)) != nil {
            throw InstallError.occupied(link.path)
        }
        try fm.createSymbolicLink(at: link, withDestinationURL: bundledTool)
        logger.notice("installed command-line tool link in \(directory.path, privacy: .public)")
        return link
    }

    static func uninstall() {
        guard let link = installedLink else { return }
        try? FileManager.default.removeItem(at: link)
        logger.notice("removed command-line tool link")
    }
}
