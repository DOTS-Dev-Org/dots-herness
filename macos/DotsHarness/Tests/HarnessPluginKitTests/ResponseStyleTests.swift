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
            XCTAssertTrue(preference.decision.guidance.contains("including passing checks"))
            XCTAssertFalse(preference.decision.guidance.contains("```chart"))
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
        XCTAssertEqual(flow[2].step?.number, 2)
        XCTAssertNil(flow[1].step?.badge)

        let audited = await MainActor.run {
            MarkdownCache.shared.parsed(for: "```flow\nHarita: şema 4 `## x` [warn: Eski şema]\nBilgi: sırada [Sırada]\n```", store: false).entries
        }
        XCTAssertEqual(audited[1].step?.note, "şema 4 `## x`")
        XCTAssertEqual(audited[1].step?.badge, DiagramTag(tone: "warn", label: "Eski şema"))
        XCTAssertEqual(audited[2].step?.badge, DiagramTag(tone: nil, label: "Sırada"))

        let spec = DiagramSpec(lines: [
            "Kural: AGENTS.md [repo] | Kişisel: Mac [local] | Git index",
            "> System prompt",
            "Model çalışır",
            "legend: repo = Repo, commit'lenir | local = Bu Mac",
        ])
        XCTAssertEqual(spec.layers.map(\.nodes.count), [3, 1])
        XCTAssertEqual(spec.layers[1].caption, "System prompt")
        XCTAssertEqual(spec.layers[0].nodes[1].note, "Mac")
        XCTAssertNil(spec.layers[0].nodes[2].group)
        XCTAssertEqual(spec.legend.map(\.group), ["repo", "local"])
        XCTAssertNotEqual(spec.color(for: "repo"), spec.color(for: "local"))
        XCTAssertEqual(spec.color(for: "ok"), .green)

        let blocks = await MainActor.run {
            MarkdownCache.shared.parsed(for: "```diagram\nA | B\n```", store: false).blocks
        }
        guard case .diagram(_, let parsed) = blocks[0] else { return XCTFail("diagram fence not grouped") }
        XCTAssertEqual(parsed.layers.first?.nodes.map(\.title), ["A", "B"])
        XCTAssertTrue(AgentResponseStylePreference.ultra.decision.guidance.contains("optional diagram"))
    }

    func testBareCountsInTaskRequestsAreNotLimits() {
        for prompt in [
            "Başlığı 5 kelime yap",
            "Add 2 words to the commit message",
            "Add a 512 token limit to the prompt builder",
            "Bu isteğin maliyeti 3 token",
            "Set the max_tokens limit to 512 tokens",
        ] {
            XCTAssertNil(ResponseStyleDetector.detectLimit(prompt), prompt)
            XCTAssertEqual(ResponseStyleDetector.detect(prompt).style, .standard, prompt)
        }
    }

    func testCountsWithALimitCueStillApply() {
        XCTAssertEqual(ResponseStyleDetector.detectLimit("200 token ile sınırla")?.maxOutputTokens, 200)
        XCTAssertEqual(ResponseStyleDetector.detectLimit("Keep it under 50 words")?.maxWords, 50)
        XCTAssertEqual(ResponseStyleDetector.detectLimit("max 80 words")?.maxWords, 80)
    }

    func testWordLimitsStayInThePromptWithoutProviderCap() {
        let words = ResponseStyleDetector.detect("100 kelimeyi geçme")
        XCTAssertEqual(words.maxWords, 100)
        XCTAssertNil(words.providerOutputTokenCap)
        XCTAssertEqual(ResponseStyleDetector.detect("En fazla 200 token kullan").providerOutputTokenCap, 200)
    }

    func testDarkCockpitKeepsRequestedResultsAndRequiredProgress() {
        let guidance = AgentResponseStylePreference.ultra.decision.guidance
        XCTAssertTrue(guidance.contains("including passing checks"))
        XCTAssertTrue(guidance.contains("requested result"))
        XCTAssertTrue(guidance.contains("progress updates"))
        XCTAssertFalse(guidance.contains("never narrate"))
    }

    func testPlainFenceIsOneCopyableBlock() async {
        let blocks = await MainActor.run {
            MarkdownCache.shared.parsed(for: "Akış:\n```\n┌─┐\n└─┘\n```\nSon", store: false).blocks
        }
        XCTAssertEqual(blocks.count, 3)
        guard case .code(_, let lines) = blocks[1] else {
            return XCTFail("expected a code block, got \(blocks)")
        }
        XCTAssertEqual(lines, ["┌─┐", "└─┘"])
    }
}
