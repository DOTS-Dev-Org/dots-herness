// Copyright (c) 2026 DOTS
// Read-only bridge from the native app into plugins. The app registers named
// snapshot providers; native plugins read
// the current snapshot through `harness.host("<topic>")`. No write path — a
// plugin can look at app state, never mutate it here.

import Foundation

@MainActor
public final class HostDataRegistry {
    private var topics: [String: () -> JSONValue] = [:]

    public init() {}

    /// Native app: expose `topic` as a live read-only snapshot. Re-registering
    /// replaces the provider. The closure runs on every plugin read, so keep it
    /// cheap and return already-computed values.
    public func register(_ topic: String, _ snapshot: @escaping () -> JSONValue) {
        topics[topic] = snapshot
    }

    public func unregister(_ topic: String) {
        topics.removeValue(forKey: topic)
    }

    /// Plugin-facing: current snapshot for `topic`, or nil if unknown.
    public func snapshot(_ topic: String) -> JSONValue? {
        topics[topic]?()
    }

    public func availableTopics() -> [String] {
        topics.keys.sorted()
    }
}
