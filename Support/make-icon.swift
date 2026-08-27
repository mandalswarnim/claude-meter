// Renders the app icon: coral squircle with two white usage bars,
// echoing the widget design. Run via build-icon.sh.
import AppKit

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let s = size
    // macOS icons leave a margin around the squircle (~10% each side).
    let inset = s * 0.10
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = rect.width * 0.225
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    let top = NSColor(calibratedRed: 0.89, green: 0.53, blue: 0.40, alpha: 1)
    let bottom = NSColor(calibratedRed: 0.80, green: 0.40, blue: 0.28, alpha: 1)
    NSGradient(starting: top, ending: bottom)?.draw(in: squircle, angle: -90)

    // Subtle inner shadow line at the top for depth.
    NSColor.white.withAlphaComponent(0.18).setStroke()
    let highlight = NSBezierPath(roundedRect: rect.insetBy(dx: s * 0.006, dy: s * 0.006),
                                 xRadius: radius, yRadius: radius)
    highlight.lineWidth = s * 0.008
    highlight.stroke()

    // Two usage bars: a fuller one and a lighter one.
    let barHeight = rect.height * 0.10
    let barX = rect.minX + rect.width * 0.17
    let barWidth = rect.width * 0.66
    let bars: [(CGFloat, CGFloat, CGFloat)] = [   // (y offset factor, fill fraction, track alpha)
        (0.58, 0.62, 0.30),
        (0.32, 0.30, 0.30),
    ]
    for (yFactor, fill, trackAlpha) in bars {
        let y = rect.minY + rect.height * yFactor
        let track = NSRect(x: barX, y: y, width: barWidth, height: barHeight)
        NSColor.white.withAlphaComponent(trackAlpha).setFill()
        NSBezierPath(roundedRect: track, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
        let filled = NSRect(x: barX, y: y, width: barWidth * fill, height: barHeight)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: filled, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
    }

    image.unlockFocus()
    return image
}

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (name, pixels) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                       ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
                       ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let img = drawIcon(size: CGFloat(pixels))
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { continue }
    rep.size = NSSize(width: pixels, height: pixels)
    guard let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: out.appendingPathComponent("\(name).png"))
}
print("iconset written to \(out.path)")
