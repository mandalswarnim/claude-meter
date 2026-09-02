import Foundation

// MARK: - Data model

enum FetchErrorKind: String, Codable {
    case auth        // credentials missing or rejected
    case network     // no connectivity / timeout
    case service     // Anthropic returned an error or unparseable payload
    case rateLimited // too many usage checks; back off until retryAfter

    /// Tolerates values written by a different build. A strict decode here
    /// fails the whole StoreState, which used to discard the last good reading.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FetchErrorKind(rawValue: raw) ?? .service
    }
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

/// Tolerant decoding, for the same reason as StoreState's below: Swift's
/// synthesized decoder ignores property defaults, so `extraUsageEnabled` was a
/// required key and a file written by a build without it threw — discarding the
/// whole snapshot and leaving the widget blank, the exact failure the lenient
/// decoding elsewhere exists to prevent. Declared in an extension so the
/// memberwise initialiser survives.
extension UsageSnapshot {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The one field a snapshot is meaningless without: if it is absent the
        // snapshot is dropped rather than shown with an invented timestamp.
        fetchedAt = try c.decode(Date.self, forKey: .fetchedAt)
        sessionPercent = try? c.decode(Int.self, forKey: .sessionPercent)
        sessionResetsAt = try? c.decode(Date.self, forKey: .sessionResetsAt)
        weeklyPercent = try? c.decode(Int.self, forKey: .weeklyPercent)
        weeklyResetsAt = try? c.decode(Date.self, forKey: .weeklyResetsAt)
        extraUsageEnabled = (try? c.decode(Bool.self, forKey: .extraUsageEnabled)) ?? false
        extraUsed = try? c.decode(Double.self, forKey: .extraUsed)
        extraLimit = try? c.decode(Double.self, forKey: .extraLimit)
        extraCurrency = try? c.decode(String.self, forKey: .extraCurrency)
        extraPercent = try? c.decode(Double.self, forKey: .extraPercent)
    }
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
    /// While set and in the future, no request may be sent — the server asked
    /// us to slow down, and spending requests anyway only extends the block.
    var retryAfter: Date?
    /// How long the last cooldown was, so consecutive rate limits back off
    /// further instead of retrying at the same cadence that caused them.
    var rateLimitBackoff: TimeInterval?
    var history: [DayHistory] = []

    var hasError: Bool { lastErrorKind != nil }

    func coolingDown(at now: Date = Date()) -> Bool {
        guard let retryAfter else { return false }
        return retryAfter > now
    }

    init() {}

    /// Every field is optional on the way in, so a file written by an older or
    /// newer build still yields whatever it does contain rather than nothing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        snapshot = try? c.decodeIfPresent(UsageSnapshot.self, forKey: .snapshot)
        lastAttemptAt = try? c.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        lastErrorKind = try? c.decodeIfPresent(FetchErrorKind.self, forKey: .lastErrorKind)
        lastErrorMessage = try? c.decodeIfPresent(String.self, forKey: .lastErrorMessage)
        retryAfter = try? c.decodeIfPresent(Date.self, forKey: .retryAfter)
        rateLimitBackoff = try? c.decodeIfPresent(TimeInterval.self, forKey: .rateLimitBackoff)
        history = (try? c.decodeIfPresent([DayHistory].self, forKey: .history)) as? [DayHistory] ?? []
    }
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
