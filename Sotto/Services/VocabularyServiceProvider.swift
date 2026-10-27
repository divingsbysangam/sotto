import AppKit
import os

/// Right-click › Services › "Add to Sotto Vocabulary" (declared as NSServices in project.yml).
final class VocabularyServiceProvider: NSObject {
    static let shared = VocabularyServiceProvider()
    private static let logger = Logger(subsystem: "com.divingsbysangam.sotto", category: "Services")

    /// Shows a brief confirmation (set by AppState to use the capsule).
    var onNotice: ((String) -> Void)?

    /// Selector from NSMessage "addToVocabulary": addToVocabulary:userData:error:.
    @objc func addToVocabulary(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let selection = pasteboard.string(forType: .string) else {
            error.pointee = "No text was selected." as NSString
            return
        }
        let words = AppSettings.vocabularyEntries(from: selection)
        guard !words.isEmpty else {
            Self.logger.notice("service: selection not added (too long or empty) chars=\(selection.count, privacy: .public)")
            onNotice?("⚠︎ Select a word or short phrase to add")
            return
        }
        let added = AppSettings.shared.addToVocabulary(words)
        Self.logger.notice("service: added=\(added.count, privacy: .public) alreadyPresent=\(words.count - added.count, privacy: .public)")
        switch added.count {
        case 0:
            onNotice?("✓ Already in Vocabulary")
        case 1:
            onNotice?("✓ Added “\(added[0])” to Vocabulary")
        default:
            onNotice?("✓ Added \(added.count) words to Vocabulary")
        }
    }
}
