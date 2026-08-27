// Copyright (c) 2026 DOTS
// Minimal 5-field cron parser for scheduled harness tasks.

import Foundation

/// A parsed standard 5-field cron expression: `minute hour day-of-month month day-of-week`.
///
/// Supported per field: `*`, a number, `a-b` ranges, `*/s` and `a-b/s` steps, and
/// comma-separated lists of the above. Day-of-week is `0-6` with `0` or `7` = Sunday.
/// When both day-of-month and day-of-week are restricted, a match on either is
/// accepted (Vixie cron semantics).
///
/// ponytail: deliberately no `@`, `L`, `W`, `#`, or named months/days. Upgrade path
/// is to extend `parseField` / add token handling if a real task needs it.
public struct CronExpression: Sendable, Equatable {
    private let minutes: Set<Int>
    private let hours: Set<Int>
    private let daysOfMonth: Set<Int>
    private let months: Set<Int>
    private let daysOfWeek: Set<Int>
    private let domRestricted: Bool
    private let dowRestricted: Bool

    public let source: String

    public init?(_ expression: String) {
        let fields = expression.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count == 5 else { return nil }
        guard
            let minutes = Self.parseField(fields[0], min: 0, max: 59),
            let hours = Self.parseField(fields[1], min: 0, max: 23),
            let daysOfMonth = Self.parseField(fields[2], min: 1, max: 31),
            let months = Self.parseField(fields[3], min: 1, max: 12),
            var daysOfWeek = Self.parseField(fields[4], min: 0, max: 7)
        else { return nil }

        if daysOfWeek.contains(7) {
            daysOfWeek.remove(7)
            daysOfWeek.insert(0)
        }

        self.minutes = minutes
        self.hours = hours
        self.daysOfMonth = daysOfMonth
        self.months = months
        self.daysOfWeek = daysOfWeek
        self.domRestricted = fields[2] != "*"
        self.dowRestricted = fields[4] != "*"
        self.source = expression
    }

    /// The first firing strictly after `date`, or `nil` if none within `limitDays`.
    public func nextDate(after date: Date, calendar: Calendar = .current, limitDays: Int = 366) -> Date? {
        var cal = calendar
        cal.timeZone = calendar.timeZone

        // Start at the next whole minute.
        guard var cursor = cal.date(bySetting: .second, value: 0, of: date) else { return nil }
        if cursor <= date {
            cursor = cal.date(byAdding: .minute, value: 1, to: cursor) ?? cursor
        }
        cursor = cal.date(bySetting: .second, value: 0, of: cursor) ?? cursor

        let deadline = cal.date(byAdding: .day, value: limitDays, to: cursor) ?? cursor
        while cursor <= deadline {
            let parts = cal.dateComponents([.minute, .hour, .day, .month, .weekday], from: cursor)
            if matches(parts) { return cursor }
            cursor = cal.date(byAdding: .minute, value: 1, to: cursor) ?? deadline.addingTimeInterval(60)
        }
        return nil
    }

    private func matches(_ parts: DateComponents) -> Bool {
        guard
            let minute = parts.minute, minutes.contains(minute),
            let hour = parts.hour, hours.contains(hour),
            let month = parts.month, months.contains(month),
            let day = parts.day,
            let weekday = parts.weekday
        else { return false }

        // Calendar weekday is 1=Sunday...7=Saturday; cron dow is 0=Sunday...6=Saturday.
        let cronDow = weekday - 1
        let domHit = daysOfMonth.contains(day)
        let dowHit = daysOfWeek.contains(cronDow)

        switch (domRestricted, dowRestricted) {
        case (false, false): return true
        case (true, false): return domHit
        case (false, true): return dowHit
        case (true, true): return domHit || dowHit
        }
    }

    private static func parseField(_ field: String, min: Int, max: Int) -> Set<Int>? {
        var values = Set<Int>()
        for part in field.split(separator: ",") {
            guard let range = parsePart(String(part), min: min, max: max) else { return nil }
            values.formUnion(range)
        }
        return values.isEmpty ? nil : values
    }

    private static func parsePart(_ part: String, min: Int, max: Int) -> [Int]? {
        var step = 1
        var body = part
        if let slash = part.firstIndex(of: "/") {
            body = String(part[part.startIndex..<slash])
            guard let parsed = Int(part[part.index(after: slash)...]), parsed > 0 else { return nil }
            step = parsed
        }

        let lower: Int
        let upper: Int
        if body == "*" {
            lower = min
            upper = max
        } else if let dash = body.firstIndex(of: "-") {
            guard
                let a = Int(body[body.startIndex..<dash]),
                let b = Int(body[body.index(after: dash)...])
            else { return nil }
            lower = a
            upper = b
        } else if let single = Int(body) {
            lower = single
            upper = single
        } else {
            return nil
        }

        guard lower >= min, upper <= max, lower <= upper else { return nil }
        return stride(from: lower, through: upper, by: step).map { $0 }
    }
}
