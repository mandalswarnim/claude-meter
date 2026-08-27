import Foundation

// MARK: - Data model

enum FetchErrorKind: String, Codable {
    case auth       // credentials missing or rejected
    case network    // no connectivity / timeout
    case service    // Anthropic returned an error or unparseable payload
}

struct UsageSnapshot: Codable {
    var sessionPercent: Int?
    var sessionResetsAt: Date?
    var weeklyPercent: Int?
    var weeklyResetsAt: Date?

    var extraUsageEnabled: Bool = false
    var extraUsed: Double?
    var extraLimit: Double?
    var extraCurrency: String?
    var extraPercent: Double?

    var fetchedAt: Date
}

struct DayHistory: Codable, Identifiable {
    var day: String            // "2026-08-26" local calendar day
    var maxSession: Int
    var lastWeekly: Int
    var id: String { day }
}

struct StoreState: Codable {
    var snapshot: UsageSnapshot?
    var lastAttemptAt: Date?
    var lastErrorKind: FetchErrorKind?
    var lastErrorMessage: String?
    var history: [DayHistory] = []

    var hasError: Bool { lastErrorKind != nil }
}

// MARK: - Formatting

enum Fmt {
    static func resetsIn(_ date: Date?, from now: Date) -> String? {
        guard let date else { return nil }
        let s = date.timeIntervalSince(now)
        if s <= 0 { return "Resetting…" }
        if s < 60 { return "Resets in <1m" }
        let minutes = Int(s / 60)
        let d = minutes / 1440, h = (minutes % 1440) / 60, m = minutes % 60
        if d > 0 { return h > 0 ? "Resets in \(d)d \(h)h" : "Resets in \(d)d" }
        if h > 0 { return m > 0 ? "Resets in \(h)h \(m)m" : "Resets in \(h)h" }
        return "Resets in \(m)m"
    }

    static func updated(_ date: Date, from now: Date) -> String {
        let s = now.timeIntervalSince(date)
        if s < 90 { return "Updated just now" }
        let minutes = Int(s / 60)
        if minutes < 60 { return "Updated \(minutes) min ago" }
        let h = minutes / 60
        if h < 24 { return "Updated \(h)h ago" }
        return "Updated \(h / 24)d ago"
    }

    static func money(_ value: Double, currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.2f %@", value, currency)
    }

    static func localDayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func dayLabel(_ key: String, now: Date) -> String {
        if key == localDayKey(now) { return "Today" }
        if key == localDayKey(now.addingTimeInterval(-86_400)) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: key) else { return key }
        let out = DateFormatter()
        out.dateFormat = "EEE d MMM"
        return out.string(from: d)
    }
}
