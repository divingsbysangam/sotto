import Foundation

/// Vocabulary → Replacements: a spoken word or phrase always written a set way ("sotto" → "Sotto").
struct TextReplacement: Codable, Identifiable, Hashable {
    var id = UUID()
    var spoken: String
    var written: String
}

/// Vocabulary → Snippets: a spoken cue expanded to a block of text ("my calendar link" → URL).
struct TextSnippet: Codable, Identifiable, Hashable {
    var id = UUID()
    var cue: String
    var text: String
}
