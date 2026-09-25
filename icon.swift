import AppKit
import ImageIO

// Build-time tool: draws the app icon at every .icns size and writes it to argv[1].
// Blue→indigo squircle with the same eye.slash symbol as the menu bar item.
func render(_ px: Int) -> CGImage {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    // macOS icon grid: 824pt tile centered in 1024, ~185pt corner radius
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(red: 0.35, green: 0.62, blue: 1, alpha: 1),
               ending: NSColor(red: 0.29, green: 0.2, blue: 0.78, alpha: 1))!.draw(in: path, angle: -90)
    let cfg = NSImage.SymbolConfiguration(pointSize: 440 * s, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    let sym = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
    sym.draw(in: NSRect(x: tile.midX - sym.size.width / 2, y: tile.midY - sym.size.height / 2,
                        width: sym.size.width, height: sym.size.height))
    NSGraphicsContext.current = nil
    return rep.cgImage!
}

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(url as CFURL, "com.apple.icns" as CFString, sizes.count, nil)!
for px in sizes { CGImageDestinationAddImage(dest, render(px), nil) }
guard CGImageDestinationFinalize(dest) else { fatalError("icns write failed") }
