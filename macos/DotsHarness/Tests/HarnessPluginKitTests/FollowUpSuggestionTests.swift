// Copyright (c) 2026 DOTS

import XCTest
@testable import DotsHarnessCore

final class FollowUpSuggestionTests: XCTestCase {
    func testNormalizesWhitespaceAndEmptySuggestions() {
        XCTAssertNil(normalizeFollowUpSuggestion(" \n\t  "))
        XCTAssertEqual(normalizeFollowUpSuggestion("a\n\n b\t\tc"), "a b c")
    }

    func testCapsSuggestionsAt500CharactersWithoutSplittingGraphemes() {
        let raw = String(repeating: "🙂é", count: 300)
        let normalized = normalizeFollowUpSuggestion(raw)

        XCTAssertEqual(normalized?.count, 500)
        XCTAssertTrue(normalized?.allSatisfy { $0 == "🙂" || $0 == "é" } == true)
    }

    func testNormalizesUpToTwoReplyChoices() {
        XCTAssertEqual(
            normalizeFollowUpSuggestions("1. Evet, ilk öneriyi uygula.\n2) Hayır, şimdilik uygulama."),
            ["Evet, ilk öneriyi uygula.", "Hayır, şimdilik uygulama."]
        )
    }

    func testFallsBackToOneChoiceAndIgnoresDuplicateLines() {
        XCTAssertEqual(normalizeFollowUpSuggestions("  Push et  "), ["Push et"])
        XCTAssertEqual(
            normalizeFollowUpSuggestions("Push et\npush et\nBaşka seçeneği uygula\nÜçüncü seçenek"),
            ["Push et", "Başka seçeneği uygula"]
        )
        XCTAssertEqual(normalizeFollowUpSuggestions("\n  "), [])
    }

    func testKeepsShortSuggestionsUnchanged() {
        let suggestion = "Faz 1 ile devam et"
        XCTAssertEqual(normalizeFollowUpSuggestion(suggestion), suggestion)
    }

    func testKeepsNonLatinSuggestionsIntact() {
        let suggestions = [
            "Türkçe ile devam et",
            "العربية تابع الخطوة التالية",
            "日本語で次の手順に進む",
            "继续处理中文步骤",
            "Продолжить следующий шаг",
            "Συνέχισε με το επόμενο βήμα",
        ]

        for suggestion in suggestions {
            XCTAssertEqual(normalizeFollowUpSuggestion(suggestion), suggestion)
        }
    }

    func testGenerationGateRequiresSuccessfulUnpausedRunWithoutPendingQueue() {
        XCTAssertTrue(shouldGenerateFollowUp(succeeded: true, cancelled: false, paused: false, pendingQueue: false))
        XCTAssertFalse(shouldGenerateFollowUp(succeeded: true, cancelled: false, paused: false, pendingQueue: false, economy: true))
        XCTAssertFalse(shouldGenerateFollowUp(succeeded: false, cancelled: false, paused: false, pendingQueue: false))
        XCTAssertFalse(shouldGenerateFollowUp(succeeded: true, cancelled: true, paused: false, pendingQueue: false))
        XCTAssertFalse(shouldGenerateFollowUp(succeeded: true, cancelled: false, paused: true, pendingQueue: false))
        XCTAssertFalse(shouldGenerateFollowUp(succeeded: true, cancelled: false, paused: false, pendingQueue: true))
    }
}
