import Foundation

/// Time-window helpers for the cost screen. Calendar-local so "today" and
/// "this month" line up with the wall clock the user is glancing at.
///
/// Aggregation lives in `CostSummary.summarize` (single-pass over all events).
/// What's left here is the chrome the cell labels need: month name + reset
/// countdowns.
enum CostBucketing {
    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }()

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.timeZone = .current
        f.setLocalizedDateFormatFromTemplate("MMM")
        return f
    }()

    /// Short month name for the current month in the user's locale, e.g. "Apr".
    static func currentMonthLabel() -> String {
        monthFormatter.string(from: Date())
    }

    /// Compact "time remaining until next local midnight" — `5h`, `42m`,
    /// `12s`. Computed on demand so the panel always shows the correct
    /// countdown regardless of how stale the last refresh is.
    static func todayResetIn() -> String {
        let now = Date()
        guard let nextMidnight = calendar.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) else { return "<1d" }
        return Duration.compact(nextMidnight.timeIntervalSince(now))
    }

    /// Compact days-until-end-of-month: `12d`, `1d`. Always uses the same
    /// shape regardless of how close to month-end we are, so the cell
    /// caption never reverts to a phrase like "tomorrow".
    static func monthResetIn() -> String {
        let now = Date()
        guard let range = calendar.range(of: .day, in: .month, for: now),
              let day = calendar.dateComponents([.day], from: now).day else {
            return "1d"
        }
        let remaining = max(1, range.count - day)
        return "\(remaining)d"
    }
}

/// Shared `TimeInterval` → compact remaining-time string. Used by the cost
/// reset glyph, usage captions, and the notch peek pill so every surface
/// speaks the same vocabulary.
///
/// Buckets: `Ns` / `Nm` / `Nh` under a day; `Nd` at a day or more.
/// Hour remainders are dropped the same way minute remainders already
/// are (`5h`, not `5h 23m`), so a monthly Cursor reset reads `29d`
/// next to Claude's `5h` instead of `29d 22h`.
enum Duration {
    static func compact(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }
}
