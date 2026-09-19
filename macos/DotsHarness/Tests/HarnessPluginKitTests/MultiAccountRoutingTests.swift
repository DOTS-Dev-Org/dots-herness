// Copyright (c) 2026 DOTS

import XCTest
import Foundation
@testable import DotsHarnessCore

final class MultiAccountRoutingTests: XCTestCase {

    private func account(
        _ id: String,
        provider: String = "claude",
        priority: Int = 0,
        active: Bool = true,
        cooldownUntil: Date? = nil
    ) -> StoredProviderAccount {
        StoredProviderAccount(
            id: id,
            provider: provider,
            name: id,
            active: active,
            model: "claude-sonnet-4",
            baseURL: "https://example.test",
            api: "anthropic",
            credentialID: "account.\(id)",
            priority: priority,
            cooldownUntil: cooldownUntil
        )
    }

    // MARK: - orderedRoutes

    @MainActor
    func testPicksHighestRemainingQuotaFirst() {
        let router = RouterController(baseURL: "http://127.0.0.1:1")
        let accounts = [account("a", priority: 0), account("b", priority: 1), account("c", priority: 2)]
        let usage: [String: AccountUsageSnapshot] = [
            "a": .init(remainingFraction: 0.10),
            "b": .init(remainingFraction: 0.90),
            "c": .init(remainingFraction: 0.50),
        ]
        let ordered = router.orderedRoutes(accounts, model: "", preferred: nil, usage: usage, now: Date())
        XCTAssertEqual(ordered.map(\.id), ["b", "c", "a"])
    }

    @MainActor
    func testUnknownUsageSortsBetweenHealthyAndExhausted() {
        let router = RouterController(baseURL: "http://127.0.0.1:1")
        let accounts = [account("healthy", priority: 2), account("unknown", priority: 1), account("empty", priority: 0)]
        let usage: [String: AccountUsageSnapshot] = [
            "healthy": .init(remainingFraction: 0.8),
            "empty": .init(remainingFraction: 0.0),
            // "unknown" has no snapshot
        ]
        let ordered = router.orderedRoutes(accounts, model: "", preferred: nil, usage: usage, now: Date())
        XCTAssertEqual(ordered.map(\.id), ["healthy", "unknown", "empty"])
    }

    @MainActor
    func testCoolingDownAccountsGoLast() {
        let router = RouterController(baseURL: "http://127.0.0.1:1")
        let future = Date().addingTimeInterval(600)
        let accounts = [
            account("cooling", priority: 0, cooldownUntil: future),
            account("ready", priority: 5),
        ]
        let ordered = router.orderedRoutes(accounts, model: "", preferred: nil, usage: [:], now: Date())
        XCTAssertEqual(ordered.map(\.id), ["ready", "cooling"])
    }

    @MainActor
    func testExpiredCooldownIsIgnored() {
        let router = RouterController(baseURL: "http://127.0.0.1:1")
        let past = Date().addingTimeInterval(-1)
        let accounts = [account("a", priority: 1, cooldownUntil: past), account("b", priority: 0)]
        let ordered = router.orderedRoutes(accounts, model: "", preferred: nil, usage: [:], now: Date())
        XCTAssertEqual(ordered.map(\.id), ["b", "a"])
    }

    @MainActor
    func testPreferredAccountComesFirst() {
        let router = RouterController(baseURL: "http://127.0.0.1:1")
        let accounts = [account("a"), account("b"), account("c")]
        let usage: [String: AccountUsageSnapshot] = ["a": .init(remainingFraction: 0.9)]
        let ordered = router.orderedRoutes(accounts, model: "", preferred: "c", usage: usage, now: Date())
        XCTAssertEqual(ordered.first?.id, "c")
        XCTAssertEqual(Set(ordered.map(\.id)), ["a", "b", "c"])
    }

    @MainActor
    func testPreferredAccountInCooldownFallsBackToOrdering() {
        let router = RouterController(baseURL: "http://127.0.0.1:1")
        let future = Date().addingTimeInterval(600)
        let accounts = [account("a", priority: 0), account("pinned", priority: 9, cooldownUntil: future)]
        let ordered = router.orderedRoutes(accounts, model: "", preferred: "pinned", usage: [:], now: Date())
        XCTAssertEqual(ordered.first?.id, "a")
        XCTAssertEqual(ordered.last?.id, "pinned")
    }

    @MainActor
    func testInactiveAccountsAreExcluded() {
        let router = RouterController(baseURL: "http://127.0.0.1:1")
        let accounts = [account("on"), account("off", active: false)]
        let ordered = router.orderedRoutes(accounts, model: "", preferred: nil, usage: [:], now: Date())
        XCTAssertEqual(ordered.map(\.id), ["on"])
    }

    // MARK: - affinityAccountID

    @MainActor
    func testAffinityDroppedWhenModelChanged() {
        let router = RouterController(baseURL: "http://127.0.0.1:1")
        // Model changed away from the pinned model: the pin is dropped before the
        // account is even looked up.
        XCTAssertNil(router.affinityAccountID(sticky: "a", stickyModelID: "claude-sonnet-4", targetModel: "gpt-4o"))
    }

    @MainActor
    func testAffinityDroppedWhenAccountMissing() {
        let router = RouterController(baseURL: "http://127.0.0.1:1")
        XCTAssertNil(router.affinityAccountID(sticky: "ghost", stickyModelID: nil, targetModel: "auto"))
    }

    // MARK: - Conversation Codable

    func testConversationDecodesWithoutStickyFields() throws {
        let json = Data(#"{"id":"c1","title":"Old","messages":[],"modelContext":[]}"#.utf8)
        let conversation = try JSONDecoder().decode(Conversation.self, from: json)
        XCTAssertNil(conversation.stickyAccountID)
        XCTAssertNil(conversation.stickyModelID)
    }

    func testConversationRoundTripsStickyFields() throws {
        var conversation = Conversation(id: "c1")
        conversation.stickyAccountID = "acc-7"
        conversation.stickyModelID = "claude-sonnet-4"
        let data = try JSONEncoder().encode(conversation)
        let decoded = try JSONDecoder().decode(Conversation.self, from: data)
        XCTAssertEqual(decoded.stickyAccountID, "acc-7")
        XCTAssertEqual(decoded.stickyModelID, "claude-sonnet-4")
    }

    // MARK: - RouterCatalog.groups ordering

    func testGroupsSortByLowestPriority() {
        let connections = [
            connection("x1", provider: "openai", priority: 30),
            connection("c1", provider: "claude", priority: 10),
            connection("c2", provider: "claude", priority: 11),
            connection("g1", provider: "gemini", priority: 20),
        ]
        let order = RouterCatalog.groups(from: connections).map(\.provider)
        XCTAssertEqual(order, ["claude", "gemini", "openai"])
    }

    private func connection(_ id: String, provider: String, priority: Int) -> RouterConnection {
        var account = StoredProviderAccount(
            id: id, provider: provider, name: id, model: "m",
            baseURL: "https://example.test", credentialID: "account.\(id)", priority: priority
        )
        account.active = true
        return RouterConnection(from: account)
    }
}
