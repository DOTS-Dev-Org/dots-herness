// Copyright (c) 2026 DOTS

import XCTest
@testable import DotsHarnessCore

final class LocalizationTests: XCTestCase {
    override func tearDown() {
        AppCopy.setLanguage(.system)
        super.tearDown()
    }

    func testSupportedLanguageMetadataIsComplete() {
        XCTAssertEqual(AppLanguage.supported.count, 30)
        XCTAssertEqual(Set(AppLanguage.supported.map(\.rawValue)).count, 30)
        XCTAssertEqual(Set(AppLanguage.supported.filter(\.isRTL)), Set([.ar, .ur, .fa]))
        XCTAssertEqual(AppLanguage.zhHans.localeIdentifier, "zh-CN")
        XCTAssertEqual(AppLanguage.tr.localeIdentifier, "tr-TR")
    }

    func testEveryLanguageResolvesRepresentativeNewLabels() {
        let keys = [
            "vision.title",
            "conversation.runSummary",
            "ask.title",
            "settings.selfVerification",
        ]

        for language in AppLanguage.supported {
            AppCopy.setLanguage(language)
            for key in keys {
                XCTAssertNotEqual(AppCopy.text(key), key, "\(language.rawValue): \(key)")
            }
            XCTAssertFalse(AppCopy.locale.identifier.isEmpty, language.rawValue)
        }
    }

    func testEveryLanguageResolvesTheFollowUpHintWithoutEnglishFallback() {
        AppCopy.setLanguage(.en)
        let englishHint = AppCopy.text("composer.followUp.hint")

        for language in AppLanguage.supported {
            AppCopy.setLanguage(language)
            let hint = AppCopy.text("composer.followUp.hint")
            XCTAssertNotEqual(hint, "composer.followUp.hint", language.rawValue)
            XCTAssertFalse(hint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, language.rawValue)
            if language != .en {
                XCTAssertNotEqual(hint, englishHint, language.rawValue)
            }
        }
    }

    func testLocalizedFormattingPreservesArguments() {
        AppCopy.setLanguage(.tr)
        XCTAssertEqual(
            AppCopy.format("voice.download.message", "Herness", "1 MB"),
            "Herness için yaklaşık 1 MB veri indirilecek. İndirme tamamlandığında sesli giriş açılacak. Model bu Mac’te tutulur."
        )
    }
}
