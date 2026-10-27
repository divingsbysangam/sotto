import Foundation

enum VocabularyInput {
    /// Preserve first spelling and input order, avoiding duplicate List identities.
    static func additions(from input: String, existing: [String]) -> [String] {
        var known = Set(existing.map { $0.lowercased() })
        return input.components(separatedBy: ",").compactMap { value in
            let word = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, known.insert(word.lowercased()).inserted else { return nil }
            return word
        }
    }
}
