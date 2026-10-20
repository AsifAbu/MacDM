// Draws the MacDM app icon and writes assets/AppIcon.icns.
// Usage (from the project folder):  swiftc scripts/make-icon.swift -o /tmp/make-icon && /tmp/make-icon
// The drawing matches AppIcon.make() in AppDelegate.swift (the fallback used when running from Xcode).
import AppKit

func draw(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let body = rect.insetBy(dx: size * 0.06, dy: size * 0.06)
        let shape = NSBezierPath(roundedRect: body, xRadius: size * 0.22, yRadius: size * 0.22)
        NSGradient(starting: NSColor(calibratedRed: 0.35, green: 0.62, blue: 1.0, alpha: 1),
                   ending: NSColor(calibratedRed: 0.06, green: 0.33, blue: 0.85, alpha: 1))?.draw(in: shape, angle: -90)
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.5, weight: .semibold)
        if let symbol = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let white = symbol.copy() as! NSImage
            white.lockFocus(); NSColor.white.set()
            NSRect(origin: .zero, size: white.size).fill(using: .sourceAtop); white.unlockFocus()
            let s = white.size
            white.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
        }
        return true
    }
}

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = draw(size: 1024)
for base in [16, 32, 128, 256, 512] {
    try png(master, pixels: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(master, pixels: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try FileManager.default.createDirectory(atPath: "assets", withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "assets/AppIcon.icns"]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote assets/AppIcon.icns" : "iconutil failed")
