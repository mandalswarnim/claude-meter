import SwiftUI
import WidgetKit

@main
struct ClaudeUsageWidgetBundle: WidgetBundle {
    init() {
        // Any launch of the extension (descriptor scan, gallery preview,
        // timeline render) leaves a trace the companion app can report.
        Store.recordWidgetHeartbeat()
        Store.trace("bundle.init")
    }

    var body: some Widget {
        Store.trace("bundle.body")
        return ClaudeUsageWidget()
    }
}

struct UsageEntry: TimelineEntry {
    var date: Date
    var state: StoreState
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        Store.trace("provider.placeholder")
        return UsageEntry(date: .now, state: Self.sampleState)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        Store.trace("provider.getSnapshot")
        if context.isPreview {
            completion(UsageEntry(date: .now, state: Self.sampleState))
        } else {
            let stored = Store.load()
            completion(UsageEntry(date: .now, state: stored.snapshot != nil ? stored : Self.sampleState))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        Task {
            Store.recordWidgetHeartbeat()
            Store.trace("provider.getTimeline")
            var state = Store.load()
            let age = state.snapshot.map { Date().timeIntervalSince($0.fetchedAt) } ?? .infinity
            // The companion app normally keeps the snapshot fresh — it holds the
            // Keychain token, which this sandbox can't reach. Only reach for the
            // network when the data is genuinely stale or a reset has passed,
            // and never while the service has asked us to wait.
            let resetPassed = [state.snapshot?.sessionResetsAt, state.snapshot?.weeklyResetsAt]
                .compactMap { $0 }
                .contains { $0 <= Date() && $0 > (state.snapshot?.fetchedAt ?? .distantPast) }
            if (age > 600 || resetPassed) && !state.coolingDown() && Credentials.token() != nil {
                state = await Fetcher.refresh()
            }

            // Per-minute entries keep the countdowns and "Updated…" text moving
            // without any network traffic between reloads.
            let start = Date()
            let entries = (0..<90).map { i in
                UsageEntry(date: start.addingTimeInterval(Double(i) * 60), state: state)
            }
            // Come back when the cooldown lapses if one is in force, so a rate
            // limit clears itself rather than lingering on screen.
            let next = state.retryAfter.map { max($0, start.addingTimeInterval(60)) }
                ?? start.addingTimeInterval(10 * 60)
            completion(Timeline(entries: entries, policy: .after(next)))
        }
    }

    static var sampleState: StoreState {
        var s = StoreState()
        s.snapshot = UsageSnapshot(
            sessionPercent: 13, sessionResetsAt: Date().addingTimeInterval(3.65 * 3600),
            weeklyPercent: 6, weeklyResetsAt: Date().addingTimeInterval(17.5 * 3600),
            fetchedAt: Date())
        return s
    }
}

struct ClaudeUsageWidget: Widget {
    var body: some WidgetConfiguration {
        Store.trace("widget.body")
        return StaticConfiguration(kind: "ClaudeCodeUsage", provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Claude Code Usage")
        .description("Session and weekly limits for your Claude Code subscription.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: UsageEntry

    var body: some View {
        UsageWidgetFace(size: size, state: entry.state, now: entry.date)
            .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
            .widgetURL(URL(string: "claudeusage://refresh"))
    }

    private var size: UsageWidgetSize {
        switch family {
        case .systemSmall: .small
        case .systemLarge: .large
        default: .medium
        }
    }
}
