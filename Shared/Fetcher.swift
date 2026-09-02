import Foundation

/// Fetches Claude Code subscription usage from the same endpoint the
/// Claude Code /usage screen uses, and merges the result into the store.
enum Fetcher {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Fetch, persist, and return the resulting state. Never throws:
    /// failures are recorded in the state so callers/UI can show them.
    ///
    /// `minimumInterval` coalesces bursts (a click while a scheduled refresh
    /// just ran). A rate-limit cooldown is always honoured, even when forced —
    /// the endpoint hands out 429s that outlast any single request.
    @discardableResult
    static func refresh(minimumInterval: TimeInterval = 0) async -> StoreState {
        var state = Store.load()
        let now = Date()

        if state.coolingDown(at: now) { return state }
        if minimumInterval > 0, let last = state.lastAttemptAt,
           now.timeIntervalSince(last) < minimumInterval {
            return state
        }
        // Claim the attempt on disk *before* going to the network. macOS may run
        // several timeline requests at once, in separate processes; without a
        // claim they all see the same stale timestamp and fire together, which
        // is what earns the 429 in the first place.
        state.lastAttemptAt = now
        Store.save(state)

        guard let token = Credentials.token() else {
            return commit { next in
                next.lastErrorKind = .auth
                next.lastErrorMessage = "Claude Code sign-in has expired"
            }
        }

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 {
                return commit { next in
                    next.lastErrorKind = .auth
                    next.lastErrorMessage = "Session expired — open Claude Code to sign in again"
                }
            } else if status == 429 {
                return commit { next in
                    // Trust the server's figure; otherwise double the last wait, so
                    // a sustained limit is met with patience rather than repetition.
                    let wait = retryAfterSeconds(response)
                        ?? min(max((next.rateLimitBackoff ?? 60) * 2, 120), 900)
                    next.lastErrorKind = .rateLimited
                    next.rateLimitBackoff = wait
                    next.retryAfter = Date().addingTimeInterval(wait)
                    next.lastErrorMessage = "Claude is limiting usage checks — pausing briefly"
                }
            } else if (200..<300).contains(status), let snapshot = parse(data) {
                return commit { next in
                    next.snapshot = snapshot
                    next.lastErrorKind = nil
                    next.lastErrorMessage = nil
                    // Only drop a cooldown that has already lapsed. One still in
                    // force was set by another process after this request left;
                    // it speaks for the shared budget, not for this one reply,
                    // and clearing it would let the next poll fire inside the
                    // server's window and earn a fresh 429.
                    if !next.coolingDown() {
                        next.retryAfter = nil
                        next.rateLimitBackoff = nil
                    }
                    recordHistory(&next, snapshot: snapshot)
                }
            } else {
                return commit { next in
                    next.lastErrorKind = .service
                    next.lastErrorMessage = "Claude returned an unexpected response (\(status))"
                }
            }
        } catch {
            return commit { next in
                next.lastErrorKind = .network
                next.lastErrorMessage = "Network unavailable"
            }
        }
    }

    /// Applies a result to whatever is on disk *now*, rather than to the copy
    /// loaded before the request went out. A fetch can be in flight for 15
    /// seconds, and the app and the widget refresh independently, so writing
    /// back the stale copy rolled back whatever the other process had learned
    /// meanwhile — most damagingly a rate-limit cooldown, which then let the
    /// next poll fire inside the server's window and earn a fresh 429.
    private static func commit(_ changes: (inout StoreState) -> Void) -> StoreState {
        var state = Store.load()
        changes(&state)
        Store.save(state)
        return state
    }

    /// `Retry-After` is either a delay in seconds or an HTTP date. Clamped so a
    /// hostile or malformed value can't park the app for hours.
    private static func retryAfterSeconds(_ response: URLResponse) -> TimeInterval? {
        guard let http = response as? HTTPURLResponse,
              let raw = http.value(forHTTPHeaderField: "Retry-After")?
                  .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        var seconds: TimeInterval?
        if let value = TimeInterval(raw) {
            seconds = value
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            seconds = formatter.date(from: raw)?.timeIntervalSinceNow
        }
        guard let seconds else { return nil }
        return min(max(seconds, 30), 900)
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
