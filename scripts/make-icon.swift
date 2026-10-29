// Draws the MONEY! icon: 💸 on a deep squircle with a soft green glow.
import AppKit
let out = CommandLine.arguments[1]
for (size, name) in [(16,"16x16"),(32,"16x16@2x"),(32,"32x32"),(64,"32x32@2x"),(128,"128x128"),(256,"128x128@2x"),(256,"256x256"),(512,"256x256@2x"),(512,"512x512"),(1024,"512x512@2x")] {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let tile = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.10, blue: 0.14, alpha: 1), NSColor(srgbRed: 0.02, green: 0.02, blue: 0.04, alpha: 1)])!.draw(in: tile, angle: -90)
    tile.addClip()
    // soft green glow behind the emoji
    let c = NSPoint(x: s / 2, y: s / 2)
    NSGradient(colors: [NSColor(srgbRed: 0.35, green: 0.95, blue: 0.55, alpha: 0.38), NSColor(srgbRed: 0.2, green: 0.6, blue: 0.4, alpha: 0)])!
        .draw(fromCenter: c, radius: 0, toCenter: c, radius: s * 0.44, options: [])
    let emoji = "💸" as NSString
    let font = NSFont.systemFont(ofSize: s * 0.5)
    let attrs: [NSAttributedString.Key: Any] = [.font: font]
    let size = emoji.size(withAttributes: attrs)
    emoji.draw(at: NSPoint(x: (s - size.width) / 2, y: (s - size.height) / 2 + s * 0.01), withAttributes: attrs)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
