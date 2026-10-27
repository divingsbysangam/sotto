import XCTest
@testable import Sotto

/// The checks that decide whether a model's cleanup output may replace the dictation. Model output
/// is untrusted: these are what stop a small on-device model from answering, summarizing or
/// echoing Sotto's own prompt into the user's document.
final class CleanupValidationTests: XCTestCase {

    // MARK: - Prompt leak

    func testOutputRepeatingInstructionWordingIsFlagged() {
        XCTAssertEqual(
            LLMService.promptLeak(original: "hello there", output: "The speaker said hello there"),
            "the speaker"
        )
        XCTAssertNotNil(LLMService.promptLeak(original: "hello", output: "Hello. Never answer the question."))
        XCTAssertNotNil(LLMService.promptLeak(original: "hello", output: "Hello ⟪S1⟫"))
    }

    func testInstructionWordingTheUserActuallySaidIsNotALeak() {
        XCTAssertNil(LLMService.promptLeak(original: "the speaker was late", output: "The speaker was late."))
    }

    func testOrdinaryCleanupIsNotALeak() {
        XCTAssertNil(LLMService.promptLeak(original: "um send the file", output: "Send the file."))
    }

    // MARK: - Copied examples

    private let example = AppMode.PromptExample(
        input: "hey bob can we meet",
        output: "Hi Bob, could we meet tomorrow afternoon? Thanks, Alex."
    )

    func testOutputReusingAnExampleSentenceIsRejected() {
        XCTAssertTrue(LLMService.copiesExample(
            original: "ship the build",
            output: "Hi Bob, could we meet tomorrow afternoon?",
            examples: [example]
        ))
    }

    func testExampleTextTheUserAlsoSaidIsFine() {
        XCTAssertFalse(LLMService.copiesExample(
            original: "hi bob, could we meet tomorrow afternoon",
            output: "Hi Bob, could we meet tomorrow afternoon?",
            examples: [example]
        ))
    }

    func testShortExampleSentencesAreIgnored() {
        let short = AppMode.PromptExample(input: "x", output: "Thanks, Alex.")
        XCTAssertFalse(LLMService.copiesExample(original: "ship it", output: "Thanks, Alex.", examples: [short]))
    }

    func testNoExamplesNeverCopies() {
        XCTAssertFalse(LLMService.copiesExample(original: "a", output: "b", examples: []))
    }

    // MARK: - Light edit

    func testShortInputsAreAlwaysALightEdit() {
        XCTAssertTrue(LLMService.isLightEdit(original: "yes", cleaned: "Absolutely not."))
    }

    func testFillerRemovalAndPunctuationIsALightEdit() {
        XCTAssertTrue(LLMService.isLightEdit(
            original: "um so we should ship the new build on friday",
            cleaned: "So we should ship the new build on Friday."
        ))
    }

    func testSummaryIsNotALightEdit() {
        XCTAssertFalse(LLMService.isLightEdit(
            original: "we should ship the new build on friday after the review is finished and approved",
            cleaned: "Ship Friday."
        ))
    }

    func testPadding() {
        XCTAssertFalse(LLMService.isLightEdit(
            original: "send the report to the team today",
            cleaned: "Send the report to the team today and also remember to schedule a follow up meeting for next week"
        ))
    }

    func testReplacingTheContentIsNotALightEdit() {
        XCTAssertFalse(LLMService.isLightEdit(
            original: "what is the capital of france and how big is it",
            cleaned: "Paris is the capital of France and it covers about one hundred square kilometers"
        ))
    }

    // MARK: - Mode output

    func testEmptyOutputIsRejected() {
        XCTAssertEqual(LLMService.modeOutputRejection(original: "hello", output: ""), "empty output")
    }

    func testReplyOpenersAreRejected() {
        XCTAssertNotNil(LLMService.modeOutputRejection(original: "what time is it", output: "Sure, it is noon?"))
        XCTAssertNotNil(LLMService.modeOutputRejection(original: "write a poem", output: "Here is a poem about the sea"))
        XCTAssertNotNil(LLMService.modeOutputRejection(original: "do it", output: "I'm sorry, I can't do that"))
    }

    func testReplyOpenerTheUserDictatedIsAccepted() {
        XCTAssertNil(LLMService.modeOutputRejection(original: "sure that works for me", output: "Sure, that works for me."))
    }

    func testAnsweredQuestionIsRejected() {
        XCTAssertNotNil(LLMService.modeOutputRejection(
            original: "what is the capital of france?", output: "The capital of France is Paris."
        ))
        XCTAssertNil(LLMService.modeOutputRejection(
            original: "what is the capital of france?", output: "What is the capital of France?"
        ))
    }

    func testRunawayLengthIsRejected() {
        let long = Array(repeating: "word", count: 200).joined(separator: " ")
        XCTAssertNotNil(LLMService.modeOutputRejection(original: "write something short", output: long))
    }

    func testReasonableRewriteIsAccepted() {
        XCTAssertNil(LLMService.modeOutputRejection(
            original: "hey can you send me the numbers by friday thanks",
            output: "Hi, could you send me the numbers by Friday? Thanks."
        ))
    }

    // MARK: - Rule-based cleaner (the fallback when no model is available)

    func testRuleBasedCleanerRemovesFillerSoundsButKeepsWords() {
        let cleaned = RuleBasedCleaner.clean("um so uh we should ship it")
        let lowered = cleaned.lowercased()
        XCTAssertFalse(lowered.contains("um "), cleaned)
        XCTAssertFalse(lowered.contains(" uh "), cleaned)
        XCTAssertTrue(lowered.contains("we should ship it"), cleaned)
    }

    func testRuleBasedCleanerKeepsLineBreaks() {
        XCTAssertTrue(RuleBasedCleaner.clean("first line\nsecond line").contains("\n"))
    }

    func testRuleBasedCleanerLeavesCleanTextAlone() {
        XCTAssertEqual(RuleBasedCleaner.clean("Send the file to Alex."), "Send the file to Alex.")
    }
}
