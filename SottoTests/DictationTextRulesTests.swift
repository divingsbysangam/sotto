import XCTest
@testable import Sotto

/// `DictationTextRules` is pure string logic, so these tests need no settings, files or models.
final class DictationTextRulesTests: XCTestCase {

    // MARK: - Replacements

    private func replacement(_ spoken: String, _ written: String) -> TextReplacement {
        TextReplacement(spoken: spoken, written: written)
    }

    func testReplacementIsCaseInsensitiveAndWholeWord() {
        let rules = [replacement("sotto", "Sotto")]
        XCTAssertEqual(DictationTextRules.applyReplacements("tell sotto about it", rules), "tell Sotto about it")
        XCTAssertEqual(DictationTextRules.applyReplacements("SOTTO is here", rules), "Sotto is here")
        XCTAssertEqual(DictationTextRules.applyReplacements("a sottoman came", rules), "a sottoman came")
    }

    func testLongestReplacementPhraseWins() {
        let rules = [replacement("sotto", "Sotto"), replacement("sotto voce", "softly")]
        XCTAssertEqual(DictationTextRules.applyReplacements("speak sotto voce now", rules), "speak softly now")
    }

    func testReplacementOutputIsNeverMatchedAgain() {
        let rules = [replacement("a", "b"), replacement("b", "c")]
        XCTAssertEqual(DictationTextRules.applyReplacements("a", rules), "b")
    }

    func testEmptyReplacementsAreIgnored() {
        XCTAssertEqual(DictationTextRules.applyReplacements("unchanged text", []), "unchanged text")
        XCTAssertEqual(DictationTextRules.applyReplacements("unchanged text", [replacement("  ", "x")]), "unchanged text")
    }

    // MARK: - Snippets

    func testSnippetCueBecomesAPlaceholderAndExpandsBack() {
        let snippet = TextSnippet(cue: "my calendar link", text: "https://cal.example/me")
        let prepared = DictationTextRules.prepare("send my calendar link please", snippets: [snippet], voiceCommands: false)
        XCTAssertEqual(prepared.tokens.count, 1)
        let token = prepared.tokens[0]
        XCTAssertEqual(prepared.text, "send \(token) please")
        XCTAssertFalse(prepared.text.contains("cal.example"))
        XCTAssertEqual(prepared.expand("Please send \(token) now."), "Please send https://cal.example/me now.")
    }

    func testDictationOfOnlyACueSkipsCleanup() {
        let snippet = TextSnippet(cue: "my signature", text: "Best,\nAlex")
        let prepared = DictationTextRules.prepare("my signature.", snippets: [snippet], voiceCommands: false)
        XCTAssertTrue(prepared.isOnlySnippets)
        let mixed = DictationTextRules.prepare("thanks, my signature", snippets: [snippet], voiceCommands: false)
        XCTAssertFalse(mixed.isOnlySnippets)
    }

    func testSnippetsAreSubstitutedBeforeVoiceCommands() {
        // "new line" inside a snippet cue must be read as part of the cue, not as a command.
        let snippet = TextSnippet(cue: "new line item", text: "LINE ITEM")
        let prepared = DictationTextRules.prepare("add a new line item", snippets: [snippet], voiceCommands: true)
        XCTAssertFalse(prepared.text.contains("\n"))
        XCTAssertEqual(prepared.tokens.count, 1)
    }

    // MARK: - Punctuation and layout commands

    func testPunctuationCommands() {
        XCTAssertEqual(DictationTextRules.applyVoiceCommands("hello comma world"), "Hello, world")
        XCTAssertEqual(DictationTextRules.applyVoiceCommands("is it ready question mark"), "Is it ready?")
        XCTAssertEqual(DictationTextRules.applyVoiceCommands("that works exclamation point"), "That works!")
    }

    func testPeriodIsACommandOnlyAtTheEnd() {
        XCTAssertEqual(DictationTextRules.applyVoiceCommands("send it by friday period"), "Send it by friday.")
        XCTAssertEqual(DictationTextRules.applyVoiceCommands("the trial period ends soon"), "the trial period ends soon")
    }

    func testNewLineAndParagraph() {
        XCTAssertEqual(DictationTextRules.applyVoiceCommands("first line new line second line"), "First line\nSecond line")
        XCTAssertEqual(DictationTextRules.applyVoiceCommands("intro new paragraph body"), "Intro\n\nBody")
    }

    func testBulletPoint() {
        let result = DictationTextRules.applyVoiceCommands("shopping list bullet point milk bullet point eggs")
        XCTAssertTrue(result.contains("\n- milk"), result)
        XCTAssertTrue(result.contains("\n- eggs"), result)
    }

    func testCommandWordsAfterADeterminerAreLeftAlone() {
        for text in ["write a new line of code", "use the comma sparingly", "she asked a question mark was missing"] {
            XCTAssertEqual(DictationTextRules.applyVoiceCommands(text), text, text)
        }
    }

    func testSymbolCommands() {
        XCTAssertEqual(DictationTextRules.applySymbolCommands("john at sign example"), "john@example")
        XCTAssertEqual(DictationTextRules.applySymbolCommands("user underscore name"), "user_name")
    }

    func testOrdinaryDictationIsReturnedUnchanged() {
        let text = "Let's meet tomorrow at noon."
        XCTAssertEqual(DictationTextRules.applyVoiceCommands(text), text)
    }

    // MARK: - "Scratch that" and spoken corrections

    func testScratchThatAsItsOwnSentenceDropsThePreviousOne() {
        XCTAssertEqual(
            DictationTextRules.applyVoiceCommands("Send the report. Scratch that. Send the invoice."),
            "Send the invoice."
        )
    }

    func testScratchThatAtTheEndOfASentenceDropsThatSentence() {
        XCTAssertEqual(DictationTextRules.applyScratchThat("Call me tomorrow. Buy milk scratch that"), "Call me tomorrow.")
    }

    func testTimeCorrectionKeepsTheLaterValue() {
        XCTAssertEqual(DictationTextRules.applyVoiceCommands("Let's meet at 3 pm, actually 4 pm"), "Let's meet at 4 pm")
    }

    func testWeekdayCorrectionKeepsTheLaterValue() {
        XCTAssertEqual(
            DictationTextRules.applyValueCorrections("See you Tuesday, no, actually Wednesday"),
            "See you Wednesday"
        )
    }

    func testCorrectionBetweenDifferentKindsOfValueIsIgnored() {
        let text = "I counted 3 apples, actually Tuesday was better"
        XCTAssertEqual(DictationTextRules.applyValueCorrections(text), text)
    }

    // MARK: - Spoken lists

    func testSpokenListBecomesANumberedList() {
        XCTAssertEqual(
            DictationTextRules.applyVoiceCommands("My goals are: one, ship it. Two, write docs. And three, rest."),
            "My goals are:\n1. Ship it\n2. Write docs\n3. Rest"
        )
    }

    func testCountingIsNotAList() {
        XCTAssertEqual(DictationTextRules.formatEnumeration("one, two, three"), "one, two, three")
        XCTAssertEqual(DictationTextRules.formatEnumeration("only one of the two"), "only one of the two")
    }

    // MARK: - Caret adaptation

    func testMidSentenceLowercasesTheFirstWordAndAddsASpace() {
        XCTAssertEqual(DictationTextRules.adaptToCaret("We should go.", before: "I think", after: nil), " we should go.")
    }

    func testSentenceStartCapitalizes() {
        XCTAssertEqual(DictationTextRules.adaptToCaret("then we leave", before: "Done. ", after: nil), "Then we leave")
        XCTAssertEqual(DictationTextRules.adaptToCaret("hello", before: "", after: nil), "Hello")
        XCTAssertEqual(DictationTextRules.adaptToCaret("hello", before: "First line\n", after: nil), "Hello")
    }

    func testPronounIAndAcronymsStayCapitalizedMidSentence() {
        XCTAssertEqual(DictationTextRules.adaptToCaret("I agree", before: "so", after: nil), " I agree")
        XCTAssertEqual(DictationTextRules.adaptToCaret("NASA says hi", before: "from", after: nil), " NASA says hi")
    }

    func testVocabularyWordKeepsItsCapital() {
        let result = DictationTextRules.adaptToCaret(
            "Kubernetes is up", before: "the cluster", after: nil, keepCapitalized: ["Kubernetes"]
        )
        XCTAssertEqual(result, " Kubernetes is up")
    }

    func testUnreadableFieldLeavesTextUnchanged() {
        XCTAssertEqual(DictationTextRules.adaptToCaret("Hello.", before: nil, after: nil), "Hello.")
    }

    func testSingleSentenceLosesItsPeriodWhenTextFollows() {
        XCTAssertEqual(
            DictationTextRules.adaptToCaret("ship it today.", before: "We will ", after: "tomorrow at noon"),
            "ship it today "
        )
    }

    func testMultiSentenceKeepsItsPeriods() {
        XCTAssertEqual(
            DictationTextRules.adaptToCaret("Ship it. Then test.", before: "Done.\n", after: "more"),
            "Ship it. Then test. "
        )
    }

    func testListsAreNotRecased() {
        let list = "1. One\n2. Two"
        XCTAssertEqual(DictationTextRules.adaptToCaret(list, before: "Notes: ", after: nil), list)
    }

    func testSpacingAroundThePunctuationAndNeighbours() {
        XCTAssertEqual(DictationTextRules.adaptToCaret("world", before: "hello", after: nil), " world")
        XCTAssertEqual(DictationTextRules.adaptToCaret(", world", before: "hello", after: nil), ", world")
        XCTAssertEqual(DictationTextRules.adaptToCaret("big", before: "a ", after: "dog"), "big ")
    }

    // MARK: - Learning from corrections

    func testMultiWordRespellingBecomesAReplacement() {
        let correction = DictationTextRules.correctionCandidate(
            before: "please install cooper netties on the server",
            after: "please install Kubernetes on the server"
        )
        XCTAssertEqual(correction, .init(original: "cooper netties", corrected: "Kubernetes"))
        XCTAssertEqual(correction?.isSingleWord, false)
    }

    func testLowercaseToCapitalizedNameIsAVocabularyWord() {
        let correction = DictationTextRules.correctionCandidate(
            before: "we use sotto daily for notes",
            after: "we use Sotto daily for notes"
        )
        XCTAssertEqual(correction, .init(original: "sotto", corrected: "Sotto"))
        XCTAssertEqual(correction?.isSingleWord, true)
    }

    func testCaseOnlyStylingIsNotLearned() {
        XCTAssertNil(DictationTextRules.correctionCandidate(
            before: "we like Sotto very much", after: "we like sotto very much"
        ))
    }

    func testRewritesAdditionsAndTinyTextAreNotCorrections() {
        // Nothing in common at either end.
        XCTAssertNil(DictationTextRules.correctionCandidate(
            before: "send the report to bob today please", after: "mail everyone an update right now thanks"
        ))
        // Text added at the end is not an in-place fix.
        XCTAssertNil(DictationTextRules.correctionCandidate(
            before: "please send the report", after: "please send the report today"
        ))
        // Too short to anchor on both sides.
        XCTAssertNil(DictationTextRules.correctionCandidate(before: "hello world", after: "hello there"))
        // No change.
        XCTAssertNil(DictationTextRules.correctionCandidate(
            before: "nothing changed here at all", after: "nothing changed here at all"
        ))
    }

    func testReplacingAWordWithAnUnrelatedOneIsNotARespelling() {
        XCTAssertNil(DictationTextRules.correctionCandidate(
            before: "please call alice about the budget", after: "please call zachary about the budget"
        ))
    }

    func testEditDistance() {
        XCTAssertEqual(DictationTextRules.editDistance(Array("kitten"), Array("sitting")), 3)
        XCTAssertEqual(DictationTextRules.editDistance(Array(""), Array("abc")), 3)
        XCTAssertEqual(DictationTextRules.editDistance(Array("same"), Array("same")), 0)
    }

    // MARK: - File names (IDE dictation)

    func testIdentifierWordsSplitCamelSnakeAndDigits() {
        XCTAssertEqual(DictationTextRules.identifierWords("MainWindowView"), ["main", "window", "view"])
        XCTAssertEqual(DictationTextRules.identifierWords("use-auth_hook"), ["use", "auth", "hook"])
        XCTAssertEqual(DictationTextRules.identifierWords("HTTPClient2"), ["http", "client", "2"])
    }

    func testSpokenFileNameWithExtensionIsWrittenExactly() {
        let result = DictationTextRules.resolveFileNames(
            "open app state dot swift please", candidates: ["AppState.swift", "MainWindowView.swift"]
        )
        XCTAssertEqual(result.text, "open AppState.swift please")
        XCTAssertEqual(result.names, ["AppState.swift"])
    }

    func testUniqueMultiWordStemIsResolved() {
        let result = DictationTextRules.resolveFileNames(
            "check main window view first", candidates: ["MainWindowView.swift"]
        )
        XCTAssertEqual(result.text, "check MainWindowView first")
    }

    func testOrdinaryWordsAreNotTurnedIntoFileNames() {
        let text = "the app is in a good state"
        let result = DictationTextRules.resolveFileNames(text, candidates: ["AppState.swift"])
        XCTAssertEqual(result.text, text)
        XCTAssertTrue(result.names.isEmpty)
    }

    func testNoCandidatesMeansNoChange() {
        let result = DictationTextRules.resolveFileNames("app state dot swift", candidates: [])
        XCTAssertEqual(result.text, "app state dot swift")
    }
}
