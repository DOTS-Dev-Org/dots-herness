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

    func testEveryLanguageResolvesTheLocalizedSettingsLabel() {
        for language in AppLanguage.supported {
            AppCopy.setLanguage(language)
            XCTAssertNotEqual(AppCopy.text("settings.language"), "settings.language", language.rawValue)
            XCTAssertFalse(AppCopy.locale.identifier.isEmpty, language.rawValue)
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
