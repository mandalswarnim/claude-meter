import SwiftUI
import AppKit

/// Development aid: renders every widget size in light and dark mode to PNGs
/// so the design can be verified without adding widgets by hand, and so the
/// screenshots in docs/ can be regenerated in one command.
/// Run with CCU_RENDER_PREVIEWS=/output/dir.
@MainActor
enum PreviewRenderer {
    static func renderAll() {
        guard let dir = ProcessInfo.processInfo.environment["CCU_RENDER_PREVIEWS"] else { return }
        let outDir = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // Real numbers where there are any, but never a real *error*: whatever
        // happened on the last fetch is not what the healthy faces should show.
        // (The docs/ screenshots were once all rendered mid-429, so every size
        // shipped with an orange "Unable to refresh" footer.)
        var state = Store.load()
        state.lastErrorKind = nil
        state.lastErrorMessage = nil
        state.retryAfter = nil
        if state.snapshot == nil { state = sample() }
        var staleState = state
        staleState.lastErrorKind = .network
        staleState.lastErrorMessage = "The Internet connection appears to be offline."

        let sizes: [(UsageWidgetSize, String, CGSize)] = [
            (.small, "small", CGSize(width: 158, height: 158)),
            (.medium, "medium", CGSize(width: 338, height: 158)),
            (.large, "large", CGSize(width: 338, height: 354)),
        ]
        for (size, name, dims) in sizes {
            for (scheme, suffix) in [(ColorScheme.light, "light"), (.dark, "dark")] {
                render(face(state: state, size: size, dims: dims, scheme: scheme),
                       size: dims, to: outDir.appendingPathComponent("\(name)-\(suffix).png"))
            }
        }
        // Error-state variant for the medium widget: the last good reading is
        // still on screen, the footer says why it is not moving.
        render(face(state: staleState, size: .medium, dims: sizes[1].2, scheme: .light),
               size: sizes[1].2, to: outDir.appendingPathComponent("medium-error-light.png"))

        for (scheme, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            renderPanel(appearance: scheme, to: outDir.appendingPathComponent("panel-\(suffix).png"))
        }
    }

    private static func face(state: StoreState, size: UsageWidgetSize, dims: CGSize, scheme: ColorScheme) -> some View {
        UsageWidgetFace(size: size, state: state, now: Date())
            .padding(16)
            .frame(width: dims.width, height: dims.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .environment(\.colorScheme, scheme)
            .preferredColorScheme(scheme)
    }

    private static func render(_ view: some View, size: CGSize, to url: URL) {
        let appearance = NSAppearance(named: url.lastPathComponent.contains("dark") ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    /// The panel goes through a real window rather than `ImageRenderer`.
    /// ImageRenderer draws SwiftUI, but the panel's AppKit-backed controls (the
    /// refresh button, the checkbox, Quit) have no host view under it and came
    /// out as yellow "missing symbol" placeholders in the shipped screenshots.
    private static func renderPanel(appearance name: NSAppearance.Name, to url: URL) {
        let appearance = NSAppearance(named: name)
        NSApp.appearance = appearance

        let root = PanelView(expandHistory: true)
            .environmentObject(UsageController.shared)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.appearance = appearance
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)

        // A borderless offscreen window: controls only draw once they are in one.
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = appearance
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        window.displayIfNeeded()
        // Let layout and the controls' first draw settle before capturing.
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))

        // An offscreen window has no screen to inherit a backing scale from, so
        // ask for a 2x bitmap explicitly — otherwise the panel ships at half the
        // resolution of the widget faces beside it.
        let bounds = hosting.bounds
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = bounds.size
        hosting.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
        window.close()
    }

    private static func sample() -> StoreState {
        var s = StoreState()
        s.snapshot = UsageSnapshot(
            sessionPercent: 13, sessionResetsAt: Date().addingTimeInterval(3.65 * 3600),
            weeklyPercent: 6, weeklyResetsAt: Date().addingTimeInterval(17.5 * 3600),
            extraUsageEnabled: true, extraUsed: 0.81, extraLimit: 15, extraCurrency: "GBP",
            extraPercent: 5.4, fetchedAt: Date())
        return s
    }
}
