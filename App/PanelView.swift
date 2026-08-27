import SwiftUI
import ServiceManagement

struct PanelView: View {
    @EnvironmentObject private var controller: UsageController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var showHistory = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .frame(width: 280)
    }

    private func content(now: Date) -> some View {
        let state = controller.state
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Claude Code Usage")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if controller.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        controller.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh now")
                }
            }

            if let snap = state.snapshot {
                UsageSection(title: "Current session", percent: snap.sessionPercent,
                             resetsAt: snap.sessionResetsAt, now: now)
                UsageSection(title: "Weekly · All models", percent: snap.weeklyPercent,
                             resetsAt: snap.weeklyResetsAt, now: now)
                if snap.extraUsageEnabled, let used = snap.extraUsed,
                   let limit = snap.extraLimit, let currency = snap.extraCurrency {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Extra usage")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        (Text(Fmt.money(used, currency: currency)).fontWeight(.semibold)
                            + Text(" of \(Fmt.money(limit, currency: currency))").foregroundStyle(.secondary))
                            .font(.system(size: 15))
                        UsageBar(percent: snap.extraPercent.map { Int($0.rounded()) })
                    }
                }
            } else {
                connectHelp(state: state)
            }

            statusRow(state: state, now: now)

            if !state.history.isEmpty {
                DisclosureGroup(isExpanded: $showHistory) {
                    historyRows(state: state, now: now)
                } label: {
                    Text("Usage history")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Toggle("Open at login", isOn: $launchAtLogin)
                .font(.caption)
                .toggleStyle(.checkbox)
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }

            HStack {
                Text(footerInfo(now: now))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func connectHelp(state: StoreState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Not connected", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 13, weight: .semibold))
            Text("This app reads the sign-in that Claude Code already stores — nothing to paste or configure. Open a terminal, run `claude`, sign in if prompted, then refresh here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func statusRow(state: StoreState, now: Date) -> some View {
        if state.hasError && state.snapshot != nil {
            VStack(alignment: .leading, spacing: 2) {
                StatusFooter(state: state, now: now)
                if let message = state.lastErrorMessage {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if state.snapshot != nil {
            StatusFooter(state: state, now: now)
        } else if let message = state.lastErrorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func footerInfo(now: Date) -> String {
        let auto = "Refreshes every \(Int(controller.refreshInterval / 60)) min"
        guard let beat = Store.lastWidgetHeartbeat() else { return auto + " · widget not added yet" }
        let minutes = Int(now.timeIntervalSince(beat) / 60)
        return auto + (minutes < 60 ? " · widget active" : " · widget idle \(minutes / 60)h")
    }

    private func historyRows(state: StoreState, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(state.history.sorted { $0.day > $1.day }.prefix(7)) { day in
                HStack {
                    Text(Fmt.dayLabel(day.day, now: now))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Session \(day.maxSession)%")
                    Text("·").foregroundStyle(.tertiary)
                    Text("Weekly \(day.lastWeekly)%")
                }
                .font(.caption)
            }
        }
        .padding(.top, 4)
    }
}
