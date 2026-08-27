import SwiftUI

// MARK: - Palette

enum UsageStyle {
    /// Claude's coral, used as the resting bar tint; shifts to warning colors as limits near.
    static func barColor(_ percent: Int?) -> Color {
        guard let percent else { return .secondary.opacity(0.4) }
        if percent >= 90 { return Color(red: 0.86, green: 0.27, blue: 0.25) }
        if percent >= 75 { return Color(red: 0.92, green: 0.58, blue: 0.20) }
        return Color(red: 0.85, green: 0.47, blue: 0.34)
    }
}

// MARK: - Building blocks

struct UsageBar: View {
    var percent: Int?
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                if let percent {
                    Capsule()
                        .fill(UsageStyle.barColor(percent))
                        .frame(width: max(6, geo.size.width * CGFloat(min(max(percent, 0), 100)) / 100))
                }
            }
        }
        .frame(height: 6)
    }
}

struct UsageSection: View {
    var title: String
    var percent: Int?
    var resetsAt: Date?
    var now: Date
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let percent {
                (Text("\(percent)%").fontWeight(.semibold)
                    + Text(" used").foregroundStyle(.secondary))
                    .font(.system(size: compact ? 14 : 15))
            } else {
                Text("—").font(.system(size: compact ? 14 : 15)).foregroundStyle(.secondary)
            }
            UsageBar(percent: percent)
                .padding(.vertical, 1)
            Text(Fmt.resetsIn(resetsAt, from: now) ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// One-line freshness/status footer shared by all sizes.
struct StatusFooter: View {
    var state: StoreState
    var now: Date
    var body: some View {
        HStack(spacing: 4) {
            if state.lastErrorKind == .auth {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                Text("Sign in via Claude Code")
            } else if state.hasError {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(footerText ?? "Unable to refresh")
            } else if let text = footerText {
                Text(text)
            }
        }
        .font(.caption2)
        .foregroundStyle(state.hasError ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
        .lineLimit(1)
    }

    private var footerText: String? {
        guard let snap = state.snapshot else { return state.hasError ? "Unable to refresh" : nil }
        let updated = Fmt.updated(snap.fetchedAt, from: now)
        return state.hasError ? "Unable to refresh · \(updated.lowercased())" : updated
    }
}

struct WidgetHeader: View {
    var showRefresh = true
    var body: some View {
        HStack {
            Text("Claude Code")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if showRefresh {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Widget layouts

enum UsageWidgetSize { case small, medium, large }

/// The complete widget face for a given size. Pure SwiftUI — the widget target
/// wraps it in containerBackground; the app renders it in previews and the panel.
struct UsageWidgetFace: View {
    var size: UsageWidgetSize
    var state: StoreState
    var now: Date

    var body: some View {
        if state.snapshot == nil {
            emptyState
        } else {
            switch size {
            case .small: small
            case .medium: medium
            case .large: large
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeader(showRefresh: false)
            Spacer()
            if state.lastErrorKind == .auth || state.lastErrorKind == nil {
                Text("Not connected")
                    .font(.system(size: 13, weight: .semibold))
                Text("Sign in to Claude Code, then tap to refresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Unable to load usage")
                    .font(.system(size: 13, weight: .semibold))
                Text("Tap to retry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var small: some View {
        let snap = state.snapshot!
        return VStack(alignment: .leading, spacing: 2) {
            WidgetHeader(showRefresh: false)
            Spacer(minLength: 2)
            Text(snap.sessionPercent.map { "\($0)%" } ?? "—")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
            Text("Session")
                .font(.caption)
                .foregroundStyle(.secondary)
            UsageBar(percent: snap.sessionPercent)
                .padding(.vertical, 3)
            Text(Fmt.resetsIn(snap.sessionResetsAt, from: now) ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 2)
            if state.hasError {
                StatusFooter(state: state, now: now)
            } else if let weekly = snap.weeklyPercent {
                (Text("Weekly  ").foregroundStyle(.tertiary)
                    + Text("\(weekly)%").foregroundStyle(.secondary))
                    .font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var medium: some View {
        let snap = state.snapshot!
        return VStack(alignment: .leading, spacing: 6) {
            WidgetHeader()
            HStack(alignment: .top, spacing: 14) {
                UsageSection(title: "Current session", percent: snap.sessionPercent,
                             resetsAt: snap.sessionResetsAt, now: now)
                Divider().padding(.vertical, 2)
                UsageSection(title: "Weekly · All models", percent: snap.weeklyPercent,
                             resetsAt: snap.weeklyResetsAt, now: now)
            }
            .frame(maxHeight: .infinity)
            StatusFooter(state: state, now: now)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var large: some View {
        let snap = state.snapshot!
        return VStack(alignment: .leading, spacing: 12) {
            WidgetHeader()
            UsageSection(title: "Current session", percent: snap.sessionPercent,
                         resetsAt: snap.sessionResetsAt, now: now)
            Divider()
            UsageSection(title: "Weekly · All models", percent: snap.weeklyPercent,
                         resetsAt: snap.weeklyResetsAt, now: now)
            if snap.extraUsageEnabled, let used = snap.extraUsed,
               let limit = snap.extraLimit, let currency = snap.extraCurrency {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Extra usage")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    (Text(Fmt.money(used, currency: currency)).fontWeight(.semibold)
                        + Text(" of \(Fmt.money(limit, currency: currency))").foregroundStyle(.secondary))
                        .font(.system(size: 15))
                    UsageBar(percent: snap.extraPercent.map { Int($0.rounded()) })
                        .padding(.vertical, 1)
                }
            }
            Spacer(minLength: 0)
            StatusFooter(state: state, now: now)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
