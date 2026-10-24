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
        let expectedInitial = MobileLanguage.from(preferredIdentifier: Locale.preferredLanguages.first ?? "en")
        XCTAssertEqual(localization.selected, expectedInitial)
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

    func testPlanningRequestsActivatePlanModeWithoutHijackingApprovalOrReferences() {
        XCTAssertTrue(MobilePlanningIntent.shouldEnterPlanMode("Bu dosya için bir plan hazırla"))
        XCTAssertTrue(MobilePlanningIntent.shouldEnterPlanMode("Bu dosyanın planını çıkar"))
        XCTAssertEqual(MobilePlanningIntent.verdict("Planla bunu"), .ambiguous)
        XCTAssertEqual(MobilePlanningIntent.verdict("Make a planet texture"), .ambiguous)
        XCTAssertFalse(MobilePlanningIntent.shouldEnterPlanMode("Make a planet texture"))
        XCTAssertTrue(MobilePlanningIntent.shouldEnterPlanMode("I need a plan for this file"))
        XCTAssertTrue(MobilePlanningIntent.shouldEnterPlanMode("Write the plan to plan.md"))
        XCTAssertTrue(MobilePlanningIntent.shouldEnterPlanMode("Sadece sohbette plan yap"))
        XCTAssertTrue(MobilePlanningIntent.shouldEnterPlanMode("Plan moduna geç"))
        XCTAssertTrue(MobilePlanningIntent.shouldEnterPlanMode("Switch to plan mode"))
        XCTAssertTrue(MobilePlanningIntent.shouldEnterPlanMode("/plan add OAuth"))
        XCTAssertFalse(MobilePlanningIntent.shouldEnterPlanMode("Planı uygula"))
        XCTAssertFalse(MobilePlanningIntent.shouldEnterPlanMode("Read plan.md"))
        XCTAssertFalse(MobilePlanningIntent.shouldEnterPlanMode("Explain what plan mode is"))
    }

    func testProviderCatalogScopesModelsAndCredentials() {
        XCTAssertEqual(MobileAgent.providerDefinitions.map(\.id), ["anthropic", "openai", "openai-responses", "gpt"])
        XCTAssertEqual(MobileAgent.definition(for: "gpt")?.authKind, .oauth)
        XCTAssertTrue(MobileAgent.models(for: "openai").contains("gpt-5.6-luna"))
        XCTAssertFalse(MobileAgent.models(for: "anthropic").contains("gpt-5.6-luna"))
        XCTAssertNil(MobileAgent.definition(for: "unknown"))
        XCTAssertEqual(MobileAgent.credentialKey(for: "openai"), "phone.provider.openai")
        XCTAssertEqual(MobileAgent.credentialReference(for: "gpt"), "keychain:oauth.openai.accounts")
    }
}
