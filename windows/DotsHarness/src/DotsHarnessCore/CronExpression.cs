// Copyright (c) 2026 DOTS
// Minimal 5-field cron parser for scheduled harness tasks.
// Port of the macOS CronExpression.swift; keep the two in sync.

using System.Globalization;

namespace DotsHarnessCore;

/// <summary>
/// A parsed standard 5-field cron expression: minute hour day-of-month month day-of-week.
/// Supported per field: <c>*</c>, a number, <c>a-b</c> ranges, <c>*/s</c> and <c>a-b/s</c>
/// steps, and comma-separated lists. Day-of-week is 0-6 with 0 or 7 = Sunday.
/// When both day-of-month and day-of-week are restricted, a match on either is
/// accepted (Vixie cron semantics).
///
/// ponytail: no @keywords, L, W, #, or names. Extend ParsePart if a task needs it.
/// </summary>
public sealed class CronExpression
{
    private readonly HashSet<int> _minutes;
    private readonly HashSet<int> _hours;
    private readonly HashSet<int> _daysOfMonth;
    private readonly HashSet<int> _months;
    private readonly HashSet<int> _daysOfWeek;
    private readonly bool _domRestricted;
    private readonly bool _dowRestricted;

    public string Source { get; }

    private CronExpression(
        string source,
        HashSet<int> minutes,
        HashSet<int> hours,
        HashSet<int> daysOfMonth,
        HashSet<int> months,
        HashSet<int> daysOfWeek,
        bool domRestricted,
        bool dowRestricted)
    {
        Source = source;
        _minutes = minutes;
        _hours = hours;
        _daysOfMonth = daysOfMonth;
        _months = months;
        _daysOfWeek = daysOfWeek;
        _domRestricted = domRestricted;
        _dowRestricted = dowRestricted;
    }

    public static CronExpression? TryParse(string? expression)
    {
        if (string.IsNullOrWhiteSpace(expression)) return null;
        var fields = expression.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
        if (fields.Length != 5) return null;

        var minutes = ParseField(fields[0], 0, 59);
        var hours = ParseField(fields[1], 0, 23);
        var daysOfMonth = ParseField(fields[2], 1, 31);
        var months = ParseField(fields[3], 1, 12);
        var daysOfWeek = ParseField(fields[4], 0, 7);
        if (minutes is null || hours is null || daysOfMonth is null || months is null || daysOfWeek is null)
        {
            return null;
        }

        if (daysOfWeek.Remove(7))
        {
            daysOfWeek.Add(0);
        }

        return new CronExpression(
            expression,
            minutes,
            hours,
            daysOfMonth,
            months,
            daysOfWeek,
            domRestricted: fields[2] != "*",
            dowRestricted: fields[4] != "*");
    }

    /// <summary>The first firing strictly after <paramref name="after"/>, or null within <paramref name="limitDays"/>.</summary>
    public DateTimeOffset? NextDate(DateTimeOffset after, int limitDays = 366)
    {
        var cursor = new DateTimeOffset(
            after.Year, after.Month, after.Day, after.Hour, after.Minute, 0, after.Offset)
            .AddMinutes(1);
        var deadline = cursor.AddDays(limitDays);
        while (cursor <= deadline)
        {
            if (Matches(cursor)) return cursor;
            cursor = cursor.AddMinutes(1);
        }
        return null;
    }

    private bool Matches(DateTimeOffset moment)
    {
        if (!_minutes.Contains(moment.Minute)) return false;
        if (!_hours.Contains(moment.Hour)) return false;
        if (!_months.Contains(moment.Month)) return false;

        var domHit = _daysOfMonth.Contains(moment.Day);
        // DayOfWeek: Sunday = 0 ... Saturday = 6, which already matches cron.
        var dowHit = _daysOfWeek.Contains((int)moment.DayOfWeek);

        return (_domRestricted, _dowRestricted) switch
        {
            (false, false) => true,
            (true, false) => domHit,
            (false, true) => dowHit,
            (true, true) => domHit || dowHit,
        };
    }

    private static HashSet<int>? ParseField(string field, int min, int max)
    {
        var values = new HashSet<int>();
        foreach (var part in field.Split(','))
        {
            var parsed = ParsePart(part, min, max);
            if (parsed is null) return null;
            foreach (var value in parsed) values.Add(value);
        }
        return values.Count == 0 ? null : values;
    }

    private static IEnumerable<int>? ParsePart(string part, int min, int max)
    {
        var step = 1;
        var body = part;
        var slash = part.IndexOf('/');
        if (slash >= 0)
        {
            body = part[..slash];
            if (!int.TryParse(part[(slash + 1)..], NumberStyles.None, CultureInfo.InvariantCulture, out step) || step <= 0)
            {
                return null;
            }
        }

        int lower;
        int upper;
        if (body == "*")
        {
            lower = min;
            upper = max;
        }
        else
        {
            var dash = body.IndexOf('-');
            if (dash >= 0)
            {
                if (!int.TryParse(body[..dash], out lower) || !int.TryParse(body[(dash + 1)..], out upper))
                {
                    return null;
                }
            }
            else if (int.TryParse(body, out var single))
            {
                lower = single;
                upper = single;
            }
            else
            {
                return null;
            }
        }

        if (lower < min || upper > max || lower > upper) return null;

        var result = new List<int>();
        for (var value = lower; value <= upper; value += step) result.Add(value);
        return result;
    }
}
