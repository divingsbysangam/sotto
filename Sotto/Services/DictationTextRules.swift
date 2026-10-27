import Foundation
import NaturalLanguage

/// Deterministic text rules between transcription and AI cleanup: Vocabulary replacements and
/// snippets, and spoken commands / self-corrections. Pure string functions (no settings, no
/// I/O) so they can be tested in isolation. Only clear cases are rewritten; anything ambiguous
/// is left as dictated.
enum DictationTextRules {

    // MARK: - Replacements

    /// Case-insensitive, whole word/phrase, in one pass: the longest phrase wins ("sotto voce"
    /// over "sotto"), and written text is never matched again.
    static func applyReplacements(_ text: String, _ replacements: [TextReplacement]) -> String {
        let usable = replacements
            .map { (spoken: $0.spoken.trimmingCharacters(in: .whitespacesAndNewlines), written: $0.written) }
            .filter { !$0.spoken.isEmpty }
            .sorted { $0.spoken.count > $1.spoken.count }
        guard !usable.isEmpty else { return text }
        let alternatives = usable.map { "(\(phraseBody($0.spoken)))" }.joined(separator: "|")
        return rewrite(text, pattern: "(?<![\\w])(?:\(alternatives))(?![\\w])") { match, _ in
            (1...usable.count).first { match.range(at: $0).location != NSNotFound }.map { usable[$0 - 1].written }
        }
    }

    // MARK: - Snippets

    /// A dictation with snippet cues swapped for placeholder tokens (`⟪S1⟫`), so cleanup can't
    /// reword the snippet blocks. `expand` puts the blocks back afterwards.
    struct Prepared {
        let text: String
        let snippetBlocks: [String: String]
        /// N7: "scratch that" or a spoken correction changed the text.
        var usedBacktrack = false
        /// N7: a spoken list, bullet, or line break was formatted.
        var usedFormatting = false
        /// L11: file names written exactly (counted for logs).
        var resolvedFileNames = 0

        /// Tokens still in `text` (a "scratch that" may have removed one).
        var tokens: [String] {
            snippetBlocks.keys.filter { text.contains($0) }.sorted()
        }

        func expand(_ output: String) -> String {
            snippetBlocks.reduce(output) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
        }

        /// Nothing but snippet cues (and punctuation): cleanup has nothing to do.
        var isOnlySnippets: Bool {
            guard !tokens.isEmpty else { return false }
            let rest = tokens.reduce(text) { $0.replacingOccurrences(of: $1, with: "") }
            return rest.rangeOfCharacter(from: .alphanumerics) == nil
        }
    }

    /// Snippets first (so a cue is never read as a command), then spoken commands.
    static func prepare(_ text: String, snippets: [TextSnippet], voiceCommands: Bool) -> Prepared {
        var blocks: [String: String] = [:]
        var result = text
        let usable = snippets
            .map { (cue: $0.cue.trimmingCharacters(in: .whitespacesAndNewlines), text: $0.text) }
            .filter { !$0.cue.isEmpty }
            .sorted { $0.cue.count > $1.cue.count }
        for snippet in usable {
            result = rewrite(result, pattern: phrasePattern(snippet.cue)) { _, _ in
                let token = "⟪S\(blocks.count + 1)⟫"
                blocks[token] = snippet.text
                return token
            }
        }
        var usedBacktrack = false
        var usedFormatting = false
        if voiceCommands {
            usedBacktrack = applyValueCorrections(applyScratchThat(result)) != result
            let commanded = applyVoiceCommands(result)
            usedFormatting = commanded.contains("\n") && !result.contains("\n")
            result = commanded
        }
        return Prepared(text: result, snippetBlocks: blocks, usedBacktrack: usedBacktrack, usedFormatting: usedFormatting)
    }

    // MARK: - Spoken Commands

    static func applyVoiceCommands(_ text: String) -> String {
        var result = applyScratchThat(text)
        result = applyValueCorrections(result)
        result = applyPunctuationCommands(result)
        result = applySymbolCommands(result)
        result = applyLayoutCommands(result)
        result = formatEnumeration(result)
        return result == text ? text : tidy(result)
    }

    /// "scratch that" / "delete that" / "strike that" drops the sentence it ends; said as its
    /// own sentence, it drops the previous one.
    static func applyScratchThat(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "\\b(?:scratch|delete|strike) that\\b[,.!;:]*",
            options: .caseInsensitive
        ) else { return text }

        var result = text
        while let match = regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
              let range = Range(match.range, in: result) {
            var before = String(result[..<range.lowerBound])
            while let last = before.last, last.isWhitespace || ",;:".contains(last) {
                before.removeLast()
            }
            if let last = before.last, ".!?".contains(last) {
                before.removeLast()
            }
            if let boundary = before.lastIndex(where: { ".!?\n".contains($0) }) {
                before = String(before[...boundary])
            } else {
                before = ""
            }
            var after = String(result[range.upperBound...])
            if before.isEmpty || before.last.map({ ".!?\n".contains($0) }) == true {
                after = capitalizingFirstLetter(after.drop(while: { $0 == " " }).description)
                if !before.isEmpty, !before.hasSuffix("\n"), !after.isEmpty { after = " " + after }
            }
            result = before + after
        }
        return result
    }

    /// "3 pm, actually 4 pm" → "4 pm": only when both sides are the same kind of value
    /// (number/time, weekday, month, or a day like "tomorrow").
    static func applyValueCorrections(_ text: String) -> String {
        let numberWords = "zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred"
        let categories = [
            "(?:\\d+(?:[:.]\\d+)?|\(numberWords))(?:\\s?(?:am|pm|a\\.m\\.|p\\.m\\.|%|percent))?",
            "monday|tuesday|wednesday|thursday|friday|saturday|sunday",
            "january|february|march|april|may|june|july|august|september|october|november|december",
            "today|tomorrow|tonight|yesterday"
        ]
        var result = text
        for value in categories {
            let pattern = "\\b(?:\(value))(?:(?<=\\.)|\\b),?\\s+(?:no,?\\s+)?(?:actually|i mean|make that),?\\s+((?:\(value))(?:(?<=\\.)|\\b))"
            result = rewrite(result, pattern: pattern) { match, string in
                string.substring(with: match.range(at: 1))
            }
        }
        return result
    }

    /// Words that make a following "new line", "question mark", "comma"… a noun, not a command.
    private static let determiners: Set<String> = [
        "a", "an", "the", "this", "that", "each", "every", "my", "your", "his", "her", "its",
        "our", "their", "no", "any", "another", "some", "oxford", "serial"
    ]

    private static func isPrecededByDeterminer(_ string: NSString, at location: Int) -> Bool {
        let before = string.substring(to: location)
        let lastWord = before.split(whereSeparator: { !$0.isLetter }).last.map { $0.lowercased() }
        return lastWord.map(determiners.contains) ?? false
    }

    static func applyPunctuationCommands(_ text: String) -> String {
        var result = text
        // Sentence enders: the next word starts a sentence.
        let enders: [(words: String, symbol: String, lookahead: String)] = [
            ("question mark", "?", ""),
            ("exclamation (?:mark|point)", "!", ""),
            ("full stop", ".", ""),
            // "period" is an ordinary word too ("trial period ends"): only at the very end or
            // right before a line break command.
            ("period", ".", "(?=[ \\t]*(?:$|\\n|(?:new (?:line|paragraph)|next line|bullet point)\\b))")
        ]
        for ender in enders {
            let pattern = "[ \\t]*[,.;:]?[ \\t]*\\b(?:\(ender.words))\\b[,.;:!?]*\(ender.lookahead)(?:[ \\t]+(\\p{L}))?"
            result = rewrite(result, pattern: pattern) { match, string in
                if isPrecededByDeterminer(string, at: match.range.location) { return nil }
                let next = match.range(at: 1)
                return next.location == NSNotFound
                    ? ender.symbol
                    : ender.symbol + " " + string.substring(with: next).uppercased()
            }
        }
        // Clause punctuation.
        for (word, symbol) in [("comma", ","), ("semicolon", ";"), ("colon", ":")] {
            let pattern = "[ \\t]*[,;:]?[ \\t]*\\b\(word)\\b[,.;:]*"
            result = rewrite(result, pattern: pattern) { match, string in
                isPrecededByDeterminer(string, at: match.range.location) ? nil : symbol + " "
            }
        }
        return result
    }

    static func applySymbolCommands(_ text: String) -> String {
        // (spoken, symbol, joins the word before, joins the word after)
        let symbols: [(String, String, Bool, Bool)] = [
            ("at sign", "@", true, true),
            ("underscore", "_", true, true),
            ("em dash", "—", true, true),
            ("ampersand", "&", false, false),
            ("percent sign", "%", true, false),
            ("dollar sign", "$", false, true),
            ("(?:hash|pound) sign", "#", false, true),
            ("open paren(?:thesis)?", "(", false, true),
            ("close paren(?:thesis)?", ")", true, false),
            ("open quote", "\"", false, true),
            ("(?:close|end) quote|unquote", "\"", true, false)
        ]
        var result = text
        for (words, symbol, joinBefore, joinAfter) in symbols {
            let before = joinBefore ? "[ \\t,]*" : ""
            let after = joinAfter ? "[ \\t,]*" : "[,.]?"
            let pattern = "\(before)\\b(?:\(words))\\b\(after)"
            result = rewrite(result, pattern: pattern) { _, _ in
                (joinBefore ? "" : " ") + symbol + (joinAfter ? "" : " ")
            }
        }
        return result
    }

    static func applyLayoutCommands(_ text: String) -> String {
        var result = text
        let breaks: [(String, String, Bool)] = [
            ("new paragraph", "\n\n", true),
            ("new line|next line", "\n", true),
            ("bullet point", "\n- ", false)
        ]
        for (words, output, capitalizeNext) in breaks {
            let pattern = "[ \\t]*[,;:]?[ \\t]*\\b(?:\(words))\\b[,.;:]*[ \\t]*(\\p{L})?"
            result = rewrite(result, pattern: pattern) { match, string in
                if isPrecededByDeterminer(string, at: match.range.location) { return nil }
                let next = match.range(at: 1)
                guard next.location != NSNotFound else { return output }
                let letter = string.substring(with: next)
                return output + (capitalizeNext ? letter.uppercased() : letter)
            }
        }
        return result
    }

    /// "My goals are: one, ship it. Two, write docs. And three, rest." → numbered list. Each
    /// marker (one/first/1…, in order from one) must start a clause, and every item must have
    /// content, so counting ("one, two, three") and "one of the two" are left alone.
    static func formatEnumeration(_ text: String) -> String {
        guard !text.contains("\n") else { return text }
        let markers = [
            "one|first(?:ly)?|1", "two|second(?:ly)?|2", "three|third(?:ly)?|3", "four|fourth(?:ly)?|4",
            "five|fifth(?:ly)?|5", "six|sixth(?:ly)?|6", "seven|seventh(?:ly)?|7", "eight|eighth(?:ly)?|8",
            "nine|ninth(?:ly)?|9", "ten|tenth(?:ly)?|10"
        ]
        let string = text as NSString
        var positions: [NSRange] = []  // each marker incl. its trailing punctuation
        var searchFrom = 0
        for marker in markers {
            let pattern = "(?:^|(?<=[.,:;!?])|(?<=[.,:;!?][ \\t])|(?<=\\band )|(?<=\\bthen ))[ \\t]*(?:number )?\\b(?:\(marker))\\b[,.:)]?"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(
                      in: text,
                      range: NSRange(location: searchFrom, length: string.length - searchFrom)
                  ) else { break }
            positions.append(match.range)
            searchFrom = NSMaxRange(match.range)
        }
        guard positions.count >= 2 else { return text }

        var items: [String] = []
        for (index, marker) in positions.enumerated() {
            let start = NSMaxRange(marker)
            let end = index + 1 < positions.count ? positions[index + 1].location : string.length
            var item = string.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespaces)
            if item.lowercased().hasSuffix(" and") { item = String(item.dropLast(4)) }
            if item.lowercased().hasSuffix(" then") { item = String(item.dropLast(5)) }
            item = item.trimmingCharacters(in: CharacterSet(charactersIn: " ,;"))
            guard item.rangeOfCharacter(from: .letters) != nil else { return text }
            items.append(item)
        }

        // Text after the last item's first sentence continues below the list.
        var trailing = ""
        if let last = items.last,
           let sentenceEnd = last.range(of: "[.!?][ \\t]+(?=\\p{Lu})", options: .regularExpression) {
            trailing = String(last[sentenceEnd.upperBound...])
            items[items.count - 1] = String(last[..<sentenceEnd.lowerBound])
        }

        var intro = string.substring(to: positions[0].location).trimmingCharacters(in: .whitespaces)
        while let last = intro.last, ",;".contains(last) { intro.removeLast() }
        if !intro.isEmpty, let last = intro.last, !".!?:".contains(last) { intro += ":" }

        let list = items.enumerated().map { index, item -> String in
            var line = capitalizingFirstLetter(item)
            if line.hasSuffix(".") && !line.hasSuffix("..") { line.removeLast() }
            return "\(index + 1). \(line)"
        }
        var output = (intro.isEmpty ? "" : intro + "\n") + list.joined(separator: "\n")
        if !trailing.isEmpty { output += "\n" + trailing }
        return output
    }

    /// Whitespace and doubled punctuation left behind by the commands. Only runs when a
    /// command changed something, so ordinary dictations are untouched.
    static func tidy(_ text: String) -> String {
        var result = text
        let rules: [(String, String)] = [
            ("[ \\t]+\\n", "\n"),
            ("\\n[ \\t]+(?!- )", "\n"),
            ("\\n{3,}", "\n\n"),
            ("[ \\t]{2,}", " "),
            ("[ \\t]+([,.!?;:%)])", "$1"),
            ("([(\"])[ \\t]+", "$1"),
            (",[ \\t]*([.!?])", "$1"),
            ("([.!?])[ \\t]*,", "$1"),
            ("([!?])\\.", "$1")
        ]
        for (pattern, template) in rules {
            result = result.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = result.first, ",;:".contains(first) {
            result = String(result.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return capitalizingFirstLetter(result)
    }

    // MARK: - Caret

    /// Blends a dictation into the text around the caret. `before` / `after` are the text just
    /// before and after the caret (nil when Accessibility can't read them: no change).
    /// - Mid-sentence: lowercase the first word, unless it's "I…", has other capitals (acronym,
    ///   iPhone), is in `keepCapitalized` (Vocabulary), or reads as a name.
    /// - Sentence start: capitalize the first letter.
    /// - Continuing text right after the caret: drop a single-sentence trailing period.
    /// - Add a space before / after when the neighbouring character isn't whitespace.
    static func adaptToCaret(_ text: String, before: String?, after: String?, keepCapitalized: Set<String> = []) -> String {
        guard let before, !text.isEmpty else { return text }
        var result = text
        // Lists, bullets, and multi-line blocks are laid out already.
        let isBlock = result.hasPrefix("\n") || result.hasPrefix("- ") || result.range(of: "^\\d+\\. ", options: .regularExpression) != nil

        let trimmedBefore = before.replacingOccurrences(of: "[ \t]+$", with: "", options: .regularExpression)
        let atSentenceStart = trimmedBefore.isEmpty
            || trimmedBefore.hasSuffix("\n")
            || trimmedBefore.range(of: "[.!?…][\"'”’)]?$", options: .regularExpression) != nil

        if !isBlock {
            if atSentenceStart {
                result = capitalizingFirstLetter(result)
            } else if let first = result.split(whereSeparator: { $0.isWhitespace }).first,
                      shouldLowercase(String(first), in: result, keepCapitalized: keepCapitalized) {
                result = lowercasingFirstLetter(result)
            }
        }

        let continuesAfter = after.flatMap { $0.first(where: { !$0.isWhitespace || $0.isNewline }) }
            .map { $0.isLetter || $0.isNumber } ?? false
        if continuesAfter, !isBlock, result.hasSuffix("."), !result.hasSuffix(".."),
           result.dropLast().rangeOfCharacter(from: CharacterSet(charactersIn: ".!?\n")) == nil {
            result.removeLast()
        }

        if let last = before.last, !last.isWhitespace, !"([{\"'“‘/@#-".contains(last),
           let first = result.first, !first.isWhitespace, !",.;:!?)]}'’”%".contains(first) {
            result = " " + result
        }
        if let next = after?.first, next.isLetter || next.isNumber,
           let last = result.last, !last.isWhitespace {
            result += " "
        }
        return result
    }

    private static func shouldLowercase(_ word: String, in text: String, keepCapitalized: Set<String>) -> Bool {
        let bare = word.trimmingCharacters(in: .punctuationCharacters)
        guard let first = bare.first, first.isUppercase else { return false }
        if bare == "I" || bare.hasPrefix("I'") || bare.hasPrefix("I’") { return false }
        if bare.dropFirst().contains(where: \.isUppercase) { return false }
        if keepCapitalized.contains(where: { $0.caseInsensitiveCompare(bare) == .orderedSame && $0.first?.isUppercase == true }) {
            return false
        }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let (tag, _) = tagger.tag(at: text.startIndex, unit: .word, scheme: .nameType)
        return ![NLTag.personalName, .placeName, .organizationName].contains(tag)
    }

    private static func lowercasingFirstLetter(_ text: String) -> String {
        guard let index = text.firstIndex(where: \.isLetter) else { return text }
        return text.replacingCharacters(in: index...index, with: text[index].lowercased())
    }

    // MARK: - File Names (L11)

    /// Spoken file names from the open project, written exactly: "app state dot swift" →
    /// `AppState.swift`, "main window view" → `MainWindowView` (a unique stem of 2+ words).
    /// Longest match first; "AppState.swift" as transcribed also matches. Returns the text and
    /// the names used.
    static func resolveFileNames(_ text: String, candidates: [String]) -> (text: String, names: [String]) {
        resolveFileNames(text, index: FileNameIndex(names: candidates))
    }

    /// Every way each file name can be spoken. Built once per project (it takes a moment for
    /// thousands of files), then used for each dictation.
    struct FileNameIndex {
        fileprivate let forms: [String: [SpokenForm]]
        let fileCount: Int

        init(names: [String]) {
            forms = DictationTextRules.spokenFileNameForms(names)
            fileCount = names.count
        }

        var isEmpty: Bool { forms.isEmpty }
    }

    static func resolveFileNames(_ text: String, index: FileNameIndex) -> (text: String, names: [String]) {
        let tokens = fileNameTokens(text)
        let forms = index.forms
        guard !tokens.isEmpty, !forms.isEmpty else { return (text, []) }
        let ns = text as NSString
        var output = ""
        var last = 0
        var used: [String] = []
        var i = 0
        while i < tokens.count {
            var matched: (length: Int, name: String)?
            for form in forms[tokens[i].key] ?? [] where form.words.count <= tokens.count - i {
                if zip(form.words, tokens[i..<(i + form.words.count)]).allSatisfy({ $0 == $1.key }) {
                    matched = (form.words.count, form.name)
                    break  // forms are longest first
                }
            }
            if let matched {
                let start = tokens[i].range.location
                let end = NSMaxRange(tokens[i + matched.length - 1].range)
                output += ns.substring(with: NSRange(location: last, length: start - last)) + matched.name
                last = end
                used.append(matched.name)
                i += matched.length
            } else {
                i += 1
            }
        }
        guard !used.isEmpty else { return (text, []) }
        output += ns.substring(from: last)
        return (output, used)
    }

    /// Resolves file names and swaps each for a placeholder (like a snippet), so cleanup can't
    /// reword or re-case them.
    static func protectFileNames(_ prepared: Prepared, index: FileNameIndex) -> Prepared {
        let resolved = resolveFileNames(prepared.text, index: index)
        guard !resolved.names.isEmpty else { return prepared }
        var blocks = prepared.snippetBlocks
        var text = resolved.text
        for name in Set(resolved.names).sorted(by: { $0.count > $1.count }) {
            let token = "⟪S\(blocks.count + 1)⟫"
            // Whole occurrences only (not inside a longer name).
            let pattern = "(?<![\\w.])" + NSRegularExpression.escapedPattern(for: name) + "(?![\\w])"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let replaced = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                                          withTemplate: NSRegularExpression.escapedTemplate(for: token))
            if replaced != text {
                blocks[token] = name
                text = replaced
            }
        }
        var result = Prepared(text: text, snippetBlocks: blocks, usedBacktrack: prepared.usedBacktrack, usedFormatting: prepared.usedFormatting)
        result.resolvedFileNames = resolved.names.count
        return result
    }

    fileprivate struct SpokenForm {
        let words: [String]
        let name: String
    }

    /// Lowercased word tokens with their ranges; a "." between two words becomes a "dot" token.
    private static func fileNameTokens(_ text: String) -> [(key: String, range: NSRange)] {
        guard let regex = try? NSRegularExpression(pattern: "[\\p{L}\\p{N}]+") else { return [] }
        let ns = text as NSString
        var tokens: [(key: String, range: NSRange)] = []
        var previousEnd: Int?
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if let previousEnd, match.range.location - previousEnd == 1, ns.substring(with: NSRange(location: previousEnd, length: 1)) == "." {
                tokens.append(("dot", NSRange(location: previousEnd, length: 1)))
            }
            tokens.append((ns.substring(with: match.range).lowercased(), match.range))
            previousEnd = NSMaxRange(match.range)
        }
        return tokens
    }

    /// Every way each name can be spoken, keyed by first word, longest first.
    fileprivate static func spokenFileNameForms(_ names: [String]) -> [String: [SpokenForm]] {
        var withExtension: [[String]: String] = [:]
        var stems: [[String]: Set<String>] = [:]
        for name in Set(names) where !name.hasPrefix(".") {
            let parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, let ext = parts.last, !ext.isEmpty, ext.count <= 10 else { continue }
            let stem = parts.dropLast().joined(separator: ".")
            let words = identifierWords(stem)
            guard !words.isEmpty else { continue }
            let joined = [words.joined()]
            let extForms: [[String]] = ext.count <= 3 && ext.allSatisfy(\.isLetter)
                ? [[ext.lowercased()], ext.lowercased().map { String($0) }]
                : [identifierWords(ext)]
            for extWords in extForms where !extWords.isEmpty {
                withExtension[words + ["dot"] + extWords] = name
                withExtension[joined + ["dot"] + extWords] = name
            }
            if words.count >= 2, words.joined().count >= 8 {
                stems[words, default: []].insert(stem)
            }
        }
        var forms = withExtension.map { SpokenForm(words: $0.key, name: $0.value) }
        // A stem alone only when it can't mean two different names.
        forms += stems.compactMap { words, names in names.count == 1 ? SpokenForm(words: words, name: names.first!) : nil }
        return Dictionary(grouping: forms) { $0.words[0] }
            .mapValues { $0.sorted { $0.words.count > $1.words.count } }
    }

    /// "MainWindowView" → [main, window, view]; "use-auth_hook" → [use, auth, hook];
    /// "HTTPClient2" → [http, client, 2].
    static func identifierWords(_ identifier: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "[A-Z]+(?![a-z])|[A-Z]?[a-z]+|[0-9]+") else { return [] }
        let ns = identifier as NSString
        return regex.matches(in: identifier, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range).lowercased() }
    }

    // MARK: - Corrections (L2)

    /// A word the user fixed by hand right after a paste.
    struct Correction: Equatable {
        /// As pasted ("cooper netties").
        let original: String
        /// As the user typed it ("Kubernetes").
        let corrected: String

        /// One word for another: a Vocabulary spelling. Otherwise a Replacement phrase.
        var isSingleWord: Bool { !original.contains(" ") && !corrected.contains(" ") }
    }

    /// The one hand correction between `before` (the text around a paste, just after pasting)
    /// and `after` (the same stretch now), or nil. Only a 1–3-word span replaced by a 1–3-word
    /// span that looks like a respelling counts; rewrites, additions, deletions, punctuation-only
    /// and case-only changes don't (except lowercase → a capitalized name).
    static func correctionCandidate(before: String, after: String) -> Correction? {
        let old = correctionTokens(before)
        let new = correctionTokens(after)
        guard old.count >= 3, old.map(\.key) != new.map(\.key) || old.map(\.text) != new.map(\.text) else { return nil }
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix].text == new[prefix].text { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - 1 - suffix].text == new[new.count - 1 - suffix].text { suffix += 1 }
        // Anchored on both sides, so it's an in-place fix rather than text added or cut at an end.
        guard prefix > 0, suffix > 0 else { return nil }
        let oldSpan = Array(old[prefix..<(old.count - suffix)])
        let newSpan = Array(new[prefix..<(new.count - suffix)])
        guard (1...3).contains(oldSpan.count), (1...3).contains(newSpan.count) else { return nil }

        let original = oldSpan.map(\.text).joined(separator: " ")
        let corrected = newSpan.map(\.text).joined(separator: " ")
        let oldKey = oldSpan.map(\.key).joined()
        let newKey = newSpan.map(\.key).joined()
        guard newKey.count >= 3, newKey.contains(where: \.isLetter) else { return nil }
        if oldKey == newKey {
            // Case only: "sotto" → "Sotto" teaches a name; anything else is just styling.
            let learnsName = original == original.lowercased() && corrected != corrected.lowercased() && oldSpan.count == newSpan.count
            return learnsName ? Correction(original: original, corrected: corrected) : nil
        }
        let distance = editDistance(Array(oldKey), Array(newKey))
        let limit = oldSpan.count == 1 && newSpan.count == 1 ? 0.5 : 0.6
        guard Double(distance) <= limit * Double(max(oldKey.count, newKey.count)) else { return nil }
        return Correction(original: original, corrected: corrected)
    }

    /// Words with surrounding punctuation trimmed; `key` also ignores case and inner punctuation.
    private static func correctionTokens(_ text: String) -> [(text: String, key: String)] {
        text.split(whereSeparator: \.isWhitespace).compactMap { raw in
            let word = String(raw).trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
            let key = word.lowercased().filter { $0.isLetter || $0.isNumber }
            return word.isEmpty || key.isEmpty ? nil : (word, key)
        }
    }

    static func editDistance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    // MARK: - Helpers

    /// Whole word/phrase, case-insensitive; spaces inside the phrase match any whitespace.
    private static func phrasePattern(_ phrase: String) -> String {
        "(?<![\\w])" + phraseBody(phrase) + "(?![\\w])"
    }

    private static func phraseBody(_ phrase: String) -> String {
        phrase.split(whereSeparator: \.isWhitespace)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "\\s+")
    }

    private static func capitalizingFirstLetter(_ text: String) -> String {
        guard let index = text.firstIndex(where: \.isLetter) else { return text }
        guard text[..<index].allSatisfy({ $0.isWhitespace || $0 == "-" || $0 == "\"" || $0 == "(" }) else { return text }
        return text.replacingCharacters(in: index...index, with: text[index].uppercased())
    }

    /// Replaces each match with `transform`'s result; nil leaves that match as it is.
    private static func rewrite(
        _ text: String,
        pattern: String,
        options: NSRegularExpression.Options = [.caseInsensitive],
        _ transform: (NSTextCheckingResult, NSString) -> String?
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let string = text as NSString
        var output = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            guard let replacement = transform(match, string) else { continue }
            output += string.substring(with: NSRange(location: last, length: match.range.location - last))
            output += replacement
            last = NSMaxRange(match.range)
        }
        output += string.substring(from: last)
        return output
    }
}
