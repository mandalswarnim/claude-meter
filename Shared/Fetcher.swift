import Foundation

/// Fetches Claude Code subscription usage from the same endpoint the
/// Claude Code /usage screen uses, and merges the result into the store.
enum Fetcher {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Fetch, persist, and return the resulting state. Never throws:
    /// failures are recorded in the state so callers/UI can show them.
    @discardableResult
    static func refresh() async -> StoreState {
        var state = Store.load()
        state.lastAttemptAt = Date()

        guard let token = Credentials.token() else {
            state.lastErrorKind = .auth
            state.lastErrorMessage = "No Claude Code credentials found"
            Store.save(state)
            return state
        }

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 {
                state.lastErrorKind = .auth
                state.lastErrorMessage = "Session expired — open Claude Code to sign in again"
            } else if (200..<300).contains(status), let snapshot = parse(data) {
                state.snapshot = snapshot
                state.lastErrorKind = nil
                state.lastErrorMessage = nil
                recordHistory(&state, snapshot: snapshot)
            } else {
                state.lastErrorKind = .service
                state.lastErrorMessage = "Claude returned an unexpected response (\(status))"
            }
        } catch {
            state.lastErrorKind = .network
            state.lastErrorMessage = "Network unavailable"
        }
        Store.save(state)
        return state
    }

    // MARK: - Parsing

    private static func parse(_ data: Data) -> UsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var snap = UsageSnapshot(fetchedAt: Date())

        // Preferred: the `limits` array (mirrors the Usage page rows).
        if let limits = root["limits"] as? [[String: Any]] {
            for limit in limits {
                let percent = (limit["percent"] as? NSNumber)?.intValue
                let resets = isoDate(limit["resets_at"] as? String)
                switch limit["kind"] as? String {
                case "session":
                    snap.sessionPercent = percent
                    snap.sessionResetsAt = resets
                case "weekly_all", "seven_day":
                    snap.weeklyPercent = percent
                    snap.weeklyResetsAt = resets
                default: break
                }
            }
        }
        // Fallback: legacy top-level windows.
        if snap.sessionPercent == nil, let w = root["five_hour"] as? [String: Any] {
            snap.sessionPercent = (w["utilization"] as? NSNumber).map { Int($0.doubleValue.rounded()) }
            snap.sessionResetsAt = isoDate(w["resets_at"] as? String)
        }
        if snap.weeklyPercent == nil, let w = root["seven_day"] as? [String: Any] {
            snap.weeklyPercent = (w["utilization"] as? NSNumber).map { Int($0.doubleValue.rounded()) }
            snap.weeklyResetsAt = isoDate(w["resets_at"] as? String)
        }

        // Extra usage credits (optional).
        if let extra = root["extra_usage"] as? [String: Any],
           (extra["is_enabled"] as? Bool) == true {
            let places = (extra["decimal_places"] as? NSNumber)?.intValue ?? 2
            let scale = pow(10.0, Double(places))
            snap.extraUsageEnabled = true
            snap.extraUsed = ((extra["used_credits"] as? NSNumber)?.doubleValue).map { $0 / scale }
            snap.extraLimit = ((extra["monthly_limit"] as? NSNumber)?.doubleValue).map { $0 / scale }
            snap.extraCurrency = extra["currency"] as? String
            snap.extraPercent = (extra["utilization"] as? NSNumber)?.doubleValue
        }

        // Refuse a snapshot with no real usage rows — better to error than invent data.
        guard snap.sessionPercent != nil || snap.weeklyPercent != nil else { return nil }
        return snap
    }

    private static func isoDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: string) { return d }
        let plain = ISO8601DateFormatter()
        return plain.date(from: string)
    }

    private static func recordHistory(_ state: inout StoreState, snapshot: UsageSnapshot) {
        let key = Fmt.localDayKey(Date())
        let session = snapshot.sessionPercent ?? 0
        let weekly = snapshot.weeklyPercent ?? 0
        if let i = state.history.firstIndex(where: { $0.day == key }) {
            state.history[i].maxSession = max(state.history[i].maxSession, session)
            state.history[i].lastWeekly = weekly
        } else {
            state.history.append(DayHistory(day: key, maxSession: session, lastWeekly: weekly))
            state.history = Array(state.history.suffix(14))
        }
    }
}
