import XCTest
@testable import DotsHarnessCore
@testable import DotsHarnessUI

final class ResponseStyleTests: XCTestCase {
    func testDetectsTurkishAndEnglishConciseRequests() {
        XCTAssertEqual(ResponseStyleDetector.detect("Kısaca ver").style, .concise)
        XCTAssertEqual(ResponseStyleDetector.detect("Özetle ve az token kullan").style, .concise)
        XCTAssertEqual(ResponseStyleDetector.detect("Use fewer tokens").style, .concise)
    }

    func testCavemanAndOneSentenceAreUltra() {
        XCTAssertEqual(ResponseStyleDetector.detect("Caveman gibi, çok kısa").style, .ultra)
        XCTAssertEqual(ResponseStyleDetector.detect("one sentence").style, .ultra)
    }

    func testDetailRequestDisablesShortMode() {
        XCTAssertEqual(ResponseStyleDetector.detect("Kısa cevap verme, detaylı anlat").style, .standard)
        XCTAssertEqual(ResponseStyleDetector.detect("Do not be brief; explain in detail").style, .standard)
    }

    func testNumericLimitsAreStrict() {
        let tokens = ResponseStyleDetector.detect("En fazla 200 token kullan")
        XCTAssertEqual(tokens.style, .strict)
        XCTAssertEqual(tokens.maxOutputTokens, 200)
        XCTAssertTrue(tokens.isHardLimit)

        let words = ResponseStyleDetector.detect("100 kelimeyi geçme")
        XCTAssertEqual(words.style, .strict)
        XCTAssertEqual(words.maxWords, 100)
    }

    func testSettingsPreferenceIsRuntimeSourceAndNumericLimitIsOnlyTurnOverride() {
        XCTAssertEqual(ResponseStyleResolver.resolve(preference: .concise, prompt: "kısaca").style, .concise)
        XCTAssertEqual(ResponseStyleResolver.resolve(preference: .detailed, prompt: "kısaca").style, .detailed)
        XCTAssertEqual(ResponseStyleResolver.resolve(preference: .balanced, prompt: "en fazla 200 token").style, .strict)
        XCTAssertTrue(AgentResponseStylePreference.ultra.decision.guidance.contains("terse"))
        XCTAssertTrue(ResponseStyleDetector.detect("en fazla 200 token kullan").guidance.contains("Do not exceed 200 output tokens"))
        XCTAssertTrue(ResponseStyleDetector.detect("en fazla 200 token kullan").guidance.contains("say what is missing"))
        XCTAssertFalse(ResponseStyleDetector.detect("en fazla 200 token kullan").guidance.contains("shortest complete"))
    }

    func testShortStylesCarryDarkCockpitRuleAndChartFenceScalesToPeak() async {
        for preference in [AgentResponseStylePreference.concise, .ultra] {
            XCTAssertTrue(preference.decision.guidance.contains("silence means normal"))
            XCTAssertTrue(preference.decision.guidance.contains("```chart"))
        }
        XCTAssertFalse(AgentResponseStylePreference.detailed.decision.guidance.contains("Dark cockpit"))

        let entries = await MainActor.run {
            MarkdownCache.shared.parsed(for: "```chart\nmacOS: 40\nLinux: 10 ms\n```\ntext", store: false).entries
        }
        XCTAssertEqual(entries.map(\.isChartFence), [true, false, false, true, false])
        XCTAssertEqual(entries[1].bar?.fraction, 1)
        XCTAssertEqual(entries[2].bar?.fraction, 0.25)
        XCTAssertEqual(entries[2].bar?.text, "10 ms")
        XCTAssertNil(entries[4].bar)

        let flow = await MainActor.run {
            MarkdownCache.shared.parsed(for: "```flow\nClient: POST /login\nAPI: 200 + token", store: false).entries
        }
        XCTAssertEqual(flow[1].step?.title, "Client")
        XCTAssertEqual(flow[1].step?.note, "POST /login")
        XCTAssertEqual(flow.map { $0.step?.isLast }, [nil, false, true])
        XCTAssertTrue(AgentResponseStylePreference.ultra.decision.guidance.contains("```flow"))
    }
}
