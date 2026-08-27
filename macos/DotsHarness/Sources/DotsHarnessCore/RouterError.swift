// Copyright (c) 2026 DOTS
// Shared localized error used by local runtimes and downloads.

import Foundation

public struct RouterError: Error, LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
