import SwiftUI
import AppKit
import Combine
import WidgetKit
import ServiceManagement

@MainActor
final class UsageController: ObservableObject {
    static let shared = UsageController()

    @Published var state: StoreState = Store.load()
    @Published var isRefreshing = false

    private var timer: Timer?
    let refreshInterval: TimeInterval = 180

    func start() {
        refresh()
        let t = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            let newState = await Fetcher.refresh()
            self.state = newState
            self.isRefreshing = false
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    var menuBarTitle: String {
        guard let pct = state.snapshot?.sessionPercent else { return "" }
        return " \(pct)%"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var cancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["CCU_RENDER_PREVIEWS"] != nil {
            PreviewRenderer.renderAll()
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        setUpStatusItem()
        Task { @MainActor in UsageController.shared.start() }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "gauge.with.needle",
                                   accessibilityDescription: "Claude Code usage")
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            button.target = self
            button.action = #selector(togglePopover)
        }

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: PanelView().environmentObject(UsageController.shared))

        cancellable = UsageController.shared.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let button = self?.statusItem?.button else { return }
                button.title = state.snapshot.map { " \($0.sessionPercent.map(String.init) ?? "–")%" } ?? ""
                if state.lastErrorKind == .auth {
                    button.image = NSImage(systemSymbolName: "person.crop.circle.badge.exclamationmark",
                                           accessibilityDescription: "Sign in needed")
                } else {
                    button.image = NSImage(systemSymbolName: "gauge.with.needle",
                                           accessibilityDescription: "Claude Code usage")
                }
                self?.writeDebugMarker()
            }
        writeDebugMarker()
    }

    /// Troubleshooting breadcrumb: records whether the status item exists and
    /// where it landed on screen (e.g. hidden behind the notch).
    private func writeDebugMarker() {
        let frame = statusItem?.button?.window?.frame ?? .zero
        let visible = statusItem?.isVisible ?? false
        let text = "statusItem visible=\(visible) frame=\(frame) screen=\(NSScreen.main?.frame.size ?? .zero) at=\(Date())"
        try? text.data(using: .utf8)?.write(
            to: Store.directory.appendingPathComponent("menubar-debug"), options: .atomic)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // claudeusage://refresh — the widget's tap target.
        Task { @MainActor in UsageController.shared.refresh() }
    }
}

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
