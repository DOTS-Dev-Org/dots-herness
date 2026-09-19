import XCTest
@testable import HerNessMobile

@MainActor
final class MobileLocalizationTests: XCTestCase {
    func testManifestLanguagesAndSystemFallback() {
        XCTAssertEqual(MobileLanguage.supported.count, 30)
        XCTAssertEqual(MobileLanguage.supported.map(\.rawValue), [
            "tr", "en", "de", "es", "fr", "it", "ja", "ko", "nl", "pt", "ru", "zh-Hans",
            "ar", "bn", "hi", "id", "vi", "ur", "mr", "te", "ta", "fa", "pl", "uk",
            "th", "ms", "ro", "el", "cs", "hu",
        ])
        XCTAssertEqual(MobileLanguage.from(preferredIdentifier: "zh-TW"), .zhHans)
        XCTAssertEqual(MobileLanguage.from(preferredIdentifier: "ar-EG"), .ar)
        XCTAssertEqual(MobileLanguage.from(preferredIdentifier: "unknown"), .en)
    }

    func testPersistenceAndRTL() {
        let suite = "herness.mobile.localization.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let localization = MobileLocalization(defaults: defaults)
        XCTAssertEqual(localization.selected, .system)
        localization.set(.fa)
        XCTAssertEqual(defaults.string(forKey: MobileLocalization.storageKey), "fa")
        XCTAssertTrue(localization.isRTL)
        XCTAssertEqual(localization.effective, .fa)
    }

    func testIntroNavigationRules() {
        XCTAssertTrue(MobileIntroNavigation.canSkip(page: 0, pageCount: 3))
        XCTAssertTrue(MobileIntroNavigation.canSkip(page: 1, pageCount: 3))
        XCTAssertFalse(MobileIntroNavigation.canSkip(page: 2, pageCount: 3))
        XCTAssertFalse(MobileIntroNavigation.showsBack(page: 0))
        XCTAssertTrue(MobileIntroNavigation.showsBack(page: 1))
        XCTAssertEqual(MobileIntroNavigation.primaryKey(page: 2, pageCount: 3), "intro.start")
    }
}
