import Foundation
import os

/// Metadata-only intervals for profiling background work in Instruments.
enum PerformanceSignposts {
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.dots.herness",
        category: .pointsOfInterest
    )

    static func begin(_ name: StaticString) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return id
    }

    static func end(_ name: StaticString, _ id: OSSignpostID) {
        os_signpost(.end, log: log, name: name, signpostID: id)
    }
}
