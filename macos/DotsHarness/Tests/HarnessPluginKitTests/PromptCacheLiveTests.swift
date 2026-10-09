import XCTest
import Foundation
import Security
import CryptoKit
@testable import DotsHarnessCore

private func cacheLiveLog(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

/// Small opt-in probes. Do not run the all-model live suite for cache validation.
final class PromptCacheLiveTests: XCTestCase {
    @MainActor private static var providerCalls = 0
    private static let requestLimit = min(50, max(0,
        Int(ProcessInfo.processInfo.environment["DOTS_CACHE_LIVE_LIMIT"] ?? "50") ?? 50))

    @MainActor
    private func probe(_ configuration: AgentConfiguration, messages: [AgentMessage], policy: AgentCachePolicy = .init()) async throws -> AgentResponse {
        guard Self.providerCalls < Self.requestLimit else { throw XCTSkip("Combined live model request budget reached.") }
        Self.providerCalls += 1
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [CacheLiveRequestBudgetProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let response = try await NativeAgentClient(configuration: configuration, session: session).complete(messages: messages, cachePolicy: policy)
        cacheLiveLog("CACHE_LIVE probe api=\(configuration.api) model=\(configuration.model) input=\(response.usage?.inputTokens.description ?? "unknown") read=\(response.usage?.cachedTokens?.description ?? "unknown") write=\(response.usage?.cacheWriteTokens?.description ?? "unknown") boundary=\(response.proposedCacheBoundary?.accepted.description ?? "unknown") reason=\(response.cacheReuseEvidence?.reason ?? "none") ttl=\(response.effectiveCacheTTLSeconds?.description ?? "unknown")")
        XCTAssertEqual(response.message.content.trimmingCharacters(in: .whitespacesAndNewlines), "OK")
        return response
    }
    @MainActor
    private func connected(_ api: String, index: Int = 0) throws -> AgentConfiguration {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DOTS_CACHE_LIVE"] == "1", "Set DOTS_CACHE_LIVE=1.")
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DOTS_CACHE_KEYCHAIN_INTERACTIVE"] == "1",
            "Live cache probe needs authorized interactive Keychain access; no provider calls sent.")
        let store = NativeProviderStore(paths: .default())
        let accounts = store.state.accounts.filter { $0.active && $0.api == api }
        try XCTSkipUnless(accounts.count > index, "Needs \(index + 1) connected \(api) account(s); no provider requests sent.")
        let account = accounts[index]
        // A headless test must not hang on a Keychain authorization dialog.
        // Interactive access is explicitly opt-in; credentials never enter logs.
        // XCTest may not share the signed app's Keychain ACL. Fail fast rather
        // than leaving a hidden authorization dialog indefinitely pending.
        // Legacy Keychain ACL prompts can ignore the per-query UI option.
        // Suppress them process-wide only while this synchronous read runs.
        var interactionAllowed: DarwinBoolean = false
        SecKeychainGetUserInteractionAllowed(&interactionAllowed)
        // DOTS_CACHE_KEYCHAIN_PROMPT=1: a person is at the keyboard and will answer the dialog.
        let prompt = ProcessInfo.processInfo.environment["DOTS_CACHE_KEYCHAIN_PROMPT"] == "1"
        SecKeychainSetUserInteractionAllowed(prompt)
        defer { SecKeychainSetUserInteractionAllowed(interactionAllowed.boolValue) }
        var value: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.dots.herness.providers",
            kSecAttrAccount as String: account.credentialID,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: prompt ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail]
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        try XCTSkipUnless(status == errSecSuccess, "CACHE_LIVE credential unavailable (Keychain status \(status)); no provider requests sent.")
        let secret = (value as? Data).flatMap { String(data: $0, encoding: .utf8) }
        let overrideKey = api == "anthropic" ? "DOTS_CACHE_CLAUDE_MODEL" : "DOTS_CACHE_CHATGPT_MODEL"
        let model = ProcessInfo.processInfo.environment[overrideKey] ?? account.model
        cacheLiveLog("CACHE_LIVE configuration api=\(api) model=\(model)")
        return AgentConfiguration(baseURL: account.baseURL, model: model,
            apiKey: try XCTUnwrap(secret), provider: RouterCatalog.label(for: account.provider), api: account.api,
            accountID: account.id, sessionAccountID: account.sessionAccountID, specID: account.provider, authType: account.authType)
    }

    private func messages(_ label: String, rules: Int = 700) -> [AgentMessage] {
        let policy = label + "\n" + (0..<rules).map { "Reference rule \($0): Preserve the supplied text exactly and answer only the requested question." }.joined(separator: "\n")
        return [.init(role: .system, content: policy, systemKind: .promptStable),
                .init(role: .user, content: "Reply with exactly OK.")]
    }

    @MainActor
    func testClaudeFiveMinuteControlAndOneHourCacheAfterSixIdleMinutes() async throws {
        var short = try connected("anthropic")
        short.anthropicCacheTTL = .fiveMinutes
        var long = short
        long.anthropicCacheTTL = .oneHour
        let nonce = UUID().uuidString
        let control = messages("Five-minute control \(nonce)")
        let extended = messages("One-hour experiment \(nonce)")
        let a = try await probe(short, messages: control)
        let b = try await probe(long, messages: extended)
        XCTAssertGreaterThan(a.usage?.cacheWriteTokens ?? 0, 0)
        XCTAssertGreaterThan(b.usage?.cacheWriteTokens ?? 0, 0)
        XCTAssertEqual(b.effectiveCacheTTLSeconds, 3600, "The endpoint must actually accept extended TTL.")
        print("CACHE_LIVE initial control_input=\(a.usage?.inputTokens ?? 0) control_write=\(a.usage?.cacheWriteTokens ?? 0) extended_write=\(b.usage?.cacheWriteTokens ?? 0)")
        for minute in 1...8 {
            try await Task.sleep(for: .seconds(45))
            print("CACHE_LIVE idle_seconds=\(minute * 45); no keepalive requests")
        }
        let controlAfter = try await probe(short, messages: control, policy: .init(priorBoundary: a.proposedCacheBoundary))
        let extendedAfter = try await probe(long, messages: extended, policy: .init(priorBoundary: b.proposedCacheBoundary))
        print("CACHE_LIVE after_6m control_read=\(controlAfter.usage?.cachedTokens ?? 0) control_write=\(controlAfter.usage?.cacheWriteTokens ?? 0) extended_read=\(extendedAfter.usage?.cachedTokens ?? 0) extended_write=\(extendedAfter.usage?.cacheWriteTokens ?? 0)")
        XCTAssertGreaterThan(controlAfter.usage?.cacheWriteTokens ?? 0, 0)
        XCTAssertGreaterThan(extendedAfter.usage?.cachedTokens ?? 0, 0)
    }

    @MainActor
    private func twentyWarmContinuations(api: String) async throws {
        let configuration = try connected(api)
        let scope = "herness:cache-live:" + UUID().uuidString
        var history = messages("Cache reuse experiment " + scope)
        var response = try await probe(configuration, messages: history,
            policy: .init(promptCacheKey: scope, comparisonScope: scope))
        var eligible = 0, reused = 0, measured = 0
        for index in 1...20 {
            history.append(response.message)
            history.append(.init(role: .user, content: "Continuation \(index). Reply with exactly OK."))
            response = try await probe(configuration, messages: history,
                policy: .init(promptCacheKey: scope, comparisonScope: scope, priorBoundary: response.proposedCacheBoundary))
            if let evidence = response.cacheReuseEvidence, evidence.classification == "eligible",
               let tokens = evidence.eligibleTokens, let read = evidence.reusedTokens {
                eligible += tokens; reused += read; measured += 1
            } else if index == 1 {
                // More paid calls cannot establish missing protocol evidence.
                throw XCTSkip("CACHE_LIVE \(api): exact eligible reuse unavailable (\(response.cacheReuseEvidence?.reason ?? "not_reported")); raw cached=\(response.usage?.cachedTokens ?? 0). Target not verified.")
            }
            print("CACHE_LIVE route=\(api) continuation=\(index) classification=\(response.cacheReuseEvidence?.classification ?? "unknown") cached=\(response.usage?.cachedTokens ?? 0) diagnostics=\(response.cacheDiagnostics?.type ?? "not_reported")")
        }
        let ratio = eligible > 0 ? Double(reused) / Double(eligible) : 0
        let coverage = Double(measured) / 20
        print("CACHE_LIVE route=\(api) reuse=\(ratio) coverage=\(coverage) calls=\(Self.providerCalls)")
        XCTAssertGreaterThanOrEqual(ratio, 0.999)
        XCTAssertGreaterThanOrEqual(coverage, 0.95)
    }

    @MainActor
    func testChatGPTTwentyWarmContinuations() async throws { try await twentyWarmContinuations(api: "chatgpt") }

    @MainActor
    func testClaudeTwentyWarmContinuations() async throws { try await twentyWarmContinuations(api: "anthropic") }

    @MainActor
    private func identicalPrefix(api: String) async throws {
        let configuration = try connected(api)
        let scope = "herness:cache-identical:" + UUID().uuidString
        let history = messages(scope)
        let first = try await probe(configuration, messages: history,
            policy: .init(promptCacheKey: scope, comparisonScope: scope))
        let second = try await probe(configuration, messages: history,
            policy: .init(promptCacheKey: scope, comparisonScope: scope, priorBoundary: first.proposedCacheBoundary))
        XCTAssertGreaterThan(try XCTUnwrap(second.usage?.cachedTokens), 0,
            "Identical prompt must report an actual provider cache read.")
        print("CACHE_LIVE identical api=\(api) model=\(configuration.model) cache_read_verified=true")
    }

    @MainActor
    func testChatGPTIdenticalPrefix() async throws { try await identicalPrefix(api: "chatgpt") }

    @MainActor
    func testClaudeIdenticalPrefix() async throws { try await identicalPrefix(api: "anthropic") }

    /// Affinity A/B: the same growing conversation is served by one pinned
    /// account (A) and by two accounts in rotation (B). The arms are interleaved
    /// so provider load drift hits both equally. Uses an unbuffered session:
    /// the budget protocol delivers the body in one piece and would hide TTFT.
    /// Without a second readable account B becomes "cold": the same account
    /// with a fresh prefix and cache key every turn, i.e. what a route that
    /// never saw this conversation would be asked to process.
    @MainActor
    func testChatGPTAccountAffinityAB() async throws {
        let first = try connected("chatgpt", index: 0)
        let second = try? connected("chatgpt", index: 1)
        let accounts = [first, second ?? first]
        let turns = min(10, max(2, Int(ProcessInfo.processInfo.environment["DOTS_CACHE_AB_TURNS"] ?? "7") ?? 7))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var arms = ["pinned", second == nil ? "cold" : "rotating"].map { name -> Arm in
            let scope = "herness:cache-ab:\(name):" + UUID().uuidString
            return Arm(name: name, scope: scope, history: messages(scope), boundaries: [nil, nil])
        }
        struct Arm { let name: String; var scope: String; var history: [AgentMessage]; var boundaries: [AgentPromptCacheBoundary?] }
        for turn in 1...turns {
            for index in arms.indices {
                guard Self.providerCalls < Self.requestLimit else { throw XCTSkip("Combined live model request budget reached.") }
                Self.providerCalls += 1
                let account = arms[index].name == "rotating" ? (turn - 1) % 2 : 0
                if arms[index].name == "cold" {
                    arms[index].scope = "herness:cache-ab:cold:" + UUID().uuidString
                    arms[index].history[0] = messages(arms[index].scope)[0]
                    arms[index].boundaries = [nil, nil]
                }
                let started = Date()
                let response = try await NativeAgentClient(configuration: accounts[account], session: session).complete(
                    messages: arms[index].history,
                    cachePolicy: .init(promptCacheKey: arms[index].scope, comparisonScope: arms[index].scope + "|\(account)",
                                       priorBoundary: arms[index].boundaries[account]))
                let total = Int(Date().timeIntervalSince(started) * 1_000)
                arms[index].boundaries[account] = response.proposedCacheBoundary
                cacheLiveLog("CACHE_AB arm=\(arms[index].name) turn=\(turn) account=\(account) input=\(response.usage?.inputTokens ?? -1) cached=\(response.usage?.cachedTokens ?? -1) output=\(response.usage?.outputTokens ?? -1) ttft_ms=\(response.firstTokenMilliseconds ?? -1) total_ms=\(total)")
                arms[index].history.append(response.message)
                arms[index].history.append(.init(role: .user, content: "Continuation \(turn). Reply with exactly OK."))
            }
        }
    }

    @MainActor
    func testChatGPTCacheResidualDiagnostics() async throws { try await cacheResidualDiagnostics(api: "chatgpt") }

    @MainActor
    func testClaudeCacheResidualDiagnostics() async throws { try await cacheResidualDiagnostics(api: "anthropic") }

    /// DOTS_CACHE_RESIDUAL_RULES is a comma-separated list of prompt sizes, e.g. "740,665".
    @MainActor
    private func cacheResidualDiagnostics(api: String) async throws {
        var configuration = try connected(api)
        if let effort = ProcessInfo.processInfo.environment["DOTS_CACHE_EFFORT"] { configuration.effort = effort }
        let selectedRules = ProcessInfo.processInfo.environment["DOTS_CACHE_RESIDUAL_RULES"]?
            .split(separator: ",").compactMap { Int($0) }
        for rules in selectedRules ?? [700, 300] {
            let scope = "herness:cache-residual:" + UUID().uuidString
            var history = messages(scope, rules: rules)
            var response: AgentResponse?
            for repeatIndex in 1...3 {
                cacheLiveLog("CACHE_RESIDUAL rules=\(rules) phase=identical repeat=\(repeatIndex)")
                response = try await probe(configuration, messages: history,
                    policy: .init(promptCacheKey: scope, comparisonScope: scope,
                                  priorBoundary: response?.proposedCacheBoundary))
            }
            if rules == 700 {
                history.append(try XCTUnwrap(response).message)
                history.append(.init(role: .user, content: "Continuation 1. Reply with exactly OK."))
                for repeatIndex in 1...2 {
                    cacheLiveLog("CACHE_RESIDUAL rules=\(rules) phase=continuation repeat=\(repeatIndex)")
                    response = try await probe(configuration, messages: history,
                        policy: .init(promptCacheKey: scope, comparisonScope: scope,
                                      priorBoundary: response?.proposedCacheBoundary))
                }
            }
        }
    }

    @MainActor
    func testChatGPTExplicitCacheBoundaryExperiment() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DOTS_CACHE_EXPERIMENT"] != nil)
        let configuration = try connected("chatgpt")
        let scope = "herness:cache-boundary:" + UUID().uuidString
        var history = messages(scope)
        var response: AgentResponse?
        for index in 1...3 {
            cacheLiveLog("CACHE_EXPERIMENT repeat=\(index)")
            response = try await probe(configuration, messages: history,
                policy: .init(promptCacheKey: scope, comparisonScope: scope,
                              priorBoundary: response?.proposedCacheBoundary))
        }
        if ProcessInfo.processInfo.environment["DOTS_CACHE_EXPERIMENT"] == "instructions" {
            history.append(try XCTUnwrap(response).message)
            history.append(.init(role: .user, content: "Continuation 1. Reply with exactly OK."))
            for index in 1...2 {
                cacheLiveLog("CACHE_EXPERIMENT continuation_repeat=\(index)")
                response = try await probe(configuration, messages: history,
                    policy: .init(promptCacheKey: scope, comparisonScope: scope,
                                  priorBoundary: response?.proposedCacheBoundary))
            }
        }
    }
}

/// Count transport attempts as well as logical probes: optional-field fallbacks
/// and ordinary retries must share the same fifty-request budget.
private final class CacheLiveRequestBudgetProtocol: URLProtocol, @unchecked Sendable {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func reserve() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let limit = min(50, max(0, Int(ProcessInfo.processInfo.environment["DOTS_CACHE_LIVE_LIMIT"] ?? "50") ?? 50))
            guard count < limit else { return false }
            count += 1
            cacheLiveLog("CACHE_LIVE transport_attempt=\(count) limit=\(limit)")
            return true
        }
    }
    private static let counter = Counter()
    private var dataTask: URLSessionDataTask?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard Self.counter.reserve() else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "CacheLiveRequestBudget", code: 50,
                userInfo: [NSLocalizedDescriptionKey: "Live model transport request limit of 50 reached."]))
            return
        }
        let trace = ProcessInfo.processInfo.environment["DOTS_CACHE_TRACE"] == "1"
        var forwarded = request
        var bodyData = request.httpBody
        if trace, bodyData == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 {
                    client?.urlProtocol(self, didFailWithError: stream.streamError ?? URLError(.cannotDecodeRawData))
                    return
                }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            bodyData = data
            forwarded.httpBodyStream = nil
            forwarded.httpBody = data
        }
        if trace, let data = bodyData,
           var body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let experiment = ProcessInfo.processInfo.environment["DOTS_CACHE_EXPERIMENT"] {
                var options = body["prompt_cache_options"] as? [String: Any] ?? [:]
                options["mode"] = "implicit"
                if ["breakpoint", "marker"].contains(experiment), var input = body["input"] as? [[String: Any]],
                   let index = input.lastIndex(where: { $0["role"] as? String == "developer" }),
                   var content = input[index]["content"] as? [[String: Any]], !content.isEmpty {
                    content[content.count - 1]["prompt_cache_breakpoint"] = ["mode": "explicit"]
                    input[index]["content"] = content
                    body["input"] = input
                }
                if experiment == "instructions", let input = body["input"] as? [[String: Any]] {
                    let stable = input.filter { $0["role"] as? String == "developer" }
                        .flatMap { $0["content"] as? [[String: Any]] ?? [] }
                        .compactMap { $0["text"] as? String }.joined(separator: "\n\n")
                    body["instructions"] = (body["instructions"] as? String ?? "") + "\n\n" + stable
                    body["input"] = input.filter { $0["role"] as? String != "developer" }
                }
                if ["breakpoint", "implicit"].contains(experiment) { body["prompt_cache_options"] = options }
                forwarded.httpBody = try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
                cacheLiveLog("CACHE_WIRE experiment=\(experiment)")
            }
            let content = body.filter { ["instructions", "input", "tools"].contains($0.key) }
            if let canonical = try? JSONSerialization.data(withJSONObject: content, options: .sortedKeys) {
                let digest = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
                let input = body["input"] as? [[String: Any]] ?? []
                let roles = input.compactMap { $0["role"] as? String }.joined(separator: ",")
                let occurrences = String(decoding: canonical, as: UTF8.self).components(separatedBy: "Reference rule 0:").count - 1
                cacheLiveLog("CACHE_WIRE content_sha256=\(digest) bytes=\(canonical.count) roles=\(roles) tools=\((body["tools"] as? [Any])?.count ?? 0) options=\(body["prompt_cache_options"] != nil) rule0_occurrences=\(occurrences)")
            }
        }
        dataTask = URLSession.shared.dataTask(with: forwarded) { [weak self] data, response, error in
            guard let self else { return }
            if let error { self.client?.urlProtocol(self, didFailWithError: error); return }
            if let response { self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
            if trace, let data {
                let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
                for line in lines where line.hasPrefix("data:") {
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    guard let event = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                          let terminal = event["response"] as? [String: Any],
                          let usage = terminal["usage"] as? [String: Any],
                          let encoded = try? JSONSerialization.data(withJSONObject: usage, options: .sortedKeys) else { continue }
                    cacheLiveLog("CACHE_RAW model=\(terminal["model"] as? String ?? "unknown") usage=\(String(decoding: encoded, as: UTF8.self)) diagnostics_present=\(terminal["prompt_cache_diagnostics"] != nil)")
                    if let diagnostics = terminal["prompt_cache_diagnostics"] as? [String: Any],
                       let encoded = try? JSONSerialization.data(withJSONObject: diagnostics.filter {
                           ["type", "reason", "comparison_reusable_tokens", "cache_missed_tokens"].contains($0.key)
                       }, options: .sortedKeys) {
                        cacheLiveLog("CACHE_RAW diagnostics=\(String(decoding: encoded, as: UTF8.self))")
                    }
                }
            }
            if let data { self.client?.urlProtocol(self, didLoad: data) }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        dataTask?.resume()
    }
    override func stopLoading() { dataTask?.cancel() }
}
