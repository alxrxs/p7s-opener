// Draws the app icon and writes Resources/AppIcon.icns (and AppIcon.png for the README).
// Run from the repo root: swift scripts/make-icon.swift
import AppKit

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    func shadow(_ alpha: CGFloat, blur: CGFloat, y: CGFloat) {
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(alpha)
        shadow.shadowBlurRadius = blur * s
        shadow.shadowOffset = NSSize(width: 0, height: y * s)
        shadow.set()
    }
    func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }

    // macOS icon grid: 824pt rounded square centred on a 1024 canvas.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s), xRadius: 185 * s, yRadius: 185 * s)
    shadow(0.3, blur: 20, y: -10)
    NSGradient(starting: rgb(0.16, 0.74, 0.70), ending: rgb(0.04, 0.38, 0.45))!.draw(in: tile, angle: -90)
    NSShadow().set()

    // Envelope back and open flap.
    let body = NSRect(x: 230 * s, y: 210 * s, width: 564 * s, height: 360 * s)
    let flap = NSBezierPath()
    flap.move(to: NSPoint(x: body.minX, y: body.maxY))
    flap.line(to: NSPoint(x: 512 * s, y: 760 * s))
    flap.line(to: NSPoint(x: body.maxX, y: body.maxY))
    flap.close()
    rgb(0.80, 0.90, 0.90).setFill()
    flap.fill()
    rgb(0.86, 0.93, 0.93).setFill()
    NSBezierPath(rect: body).fill()

    // The document rising out of it.
    let paper = NSBezierPath(roundedRect: NSRect(x: 330 * s, y: 330 * s, width: 364 * s, height: 480 * s), xRadius: 24 * s, yRadius: 24 * s)
    shadow(0.25, blur: 24, y: -8)
    NSColor.white.setFill()
    paper.fill()
    NSShadow().set()
    rgb(0.78, 0.86, 0.88).setFill()
    for (i, width) in [264.0, 240, 264, 180].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: 380 * s, y: CGFloat(720 - i * 56) * s, width: CGFloat(width) * s, height: 22 * s),
                     xRadius: 11 * s, yRadius: 11 * s).fill()
    }

    // Envelope front pocket over the document's lower half.
    let pocket = NSBezierPath()
    pocket.move(to: NSPoint(x: body.minX, y: body.minY))
    pocket.line(to: NSPoint(x: body.minX, y: body.maxY - 40 * s))
    pocket.line(to: NSPoint(x: 512 * s, y: 380 * s))
    pocket.line(to: NSPoint(x: body.maxX, y: body.maxY - 40 * s))
    pocket.line(to: NSPoint(x: body.maxX, y: body.minY))
    pocket.close()
    shadow(0.2, blur: 16, y: 6)
    NSGradient(starting: rgb(0.97, 0.99, 0.99), ending: rgb(0.88, 0.94, 0.94))!.draw(in: pocket, angle: 90)
    NSShadow().set()

    // The broken wax seal.
    let seal = NSBezierPath(ovalIn: NSRect(x: 452 * s, y: 300 * s, width: 120 * s, height: 120 * s))
    shadow(0.3, blur: 10, y: -4)
    NSGradient(starting: rgb(0.90, 0.27, 0.24), ending: rgb(0.66, 0.10, 0.12))!.draw(in: seal, angle: -90)
    NSShadow().set()
    let crack = NSBezierPath()
    crack.move(to: NSPoint(x: 500 * s, y: 420 * s))
    crack.line(to: NSPoint(x: 522 * s, y: 372 * s))
    crack.line(to: NSPoint(x: 500 * s, y: 346 * s))
    crack.line(to: NSPoint(x: 520 * s, y: 300 * s))
    crack.lineWidth = 9 * s
    crack.lineJoinStyle = .round
    rgb(0.04, 0.38, 0.45).setStroke()
    crack.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try draw(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
try fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
try draw(size: 256).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/AppIcon.png"))
print("wrote Resources/AppIcon.icns and Resources/AppIcon.png")
