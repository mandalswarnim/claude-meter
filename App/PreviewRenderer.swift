import SwiftUI
import AppKit

/// Development aid: renders every widget size in light and dark mode to PNGs
/// so the design can be verified without adding widgets by hand.
/// Run with CCU_RENDER_PREVIEWS=/output/dir.
@MainActor
enum PreviewRenderer {
    static func renderAll() {
        guard let dir = ProcessInfo.processInfo.environment["CCU_RENDER_PREVIEWS"] else { return }
        let outDir = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var state = Store.load()
        if state.snapshot == nil { state = sample() }
        var staleState = state
        staleState.lastErrorKind = .network
        staleState.lastErrorMessage = "Network unavailable"

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
        // Error-state variant for the medium widget.
        render(face(state: staleState, size: .medium, dims: sizes[1].2, scheme: .light),
               size: sizes[1].2, to: outDir.appendingPathComponent("medium-error-light.png"))

        // The companion panel, with whatever state is really on disk.
        for (scheme, suffix) in [(ColorScheme.light, "light"), (.dark, "dark")] {
            let panel = PanelView()
                .environmentObject(UsageController.shared)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
                .preferredColorScheme(scheme)
            render(panel, size: CGSize(width: 280, height: 10),
                   to: outDir.appendingPathComponent("panel-\(suffix).png"))
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
        NSAppearance.currentDrawing().performAsCurrentDrawingAppearance {}
        NSApp.appearance = appearance
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
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
