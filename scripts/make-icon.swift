// Draws the HeatBar app icon and writes Resources/AppIcon.icns.
// Run from the repo root: swift scripts/make-icon.swift
import AppKit

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    NSGraphicsContext.current!.cgContext.scaleBy(x: s, y: s)

    // Background: dark rounded square on the standard 824 pt icon grid.
    let bg = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGradient(starting: NSColor(srgbRed: 0.19, green: 0.21, blue: 0.29, alpha: 1),
               ending: NSColor(srgbRed: 0.09, green: 0.10, blue: 0.15, alpha: 1))!.draw(in: bg, angle: -90)

    // Thermometer: white tube and bulb, mercury in an orange-to-red gradient.
    let tube = NSBezierPath(roundedRect: NSRect(x: 452, y: 330, width: 120, height: 470), xRadius: 60, yRadius: 60)
    tube.append(NSBezierPath(ovalIn: NSRect(x: 397, y: 190, width: 230, height: 230)))
    NSColor.white.setFill()
    tube.fill()

    let heat = NSGradient(starting: NSColor(srgbRed: 1.00, green: 0.62, blue: 0.20, alpha: 1),
                          ending: NSColor(srgbRed: 0.93, green: 0.20, blue: 0.16, alpha: 1))!
    let mercury = NSBezierPath(roundedRect: NSRect(x: 482, y: 330, width: 60, height: 330), xRadius: 30, yRadius: 30)
    mercury.append(NSBezierPath(ovalIn: NSRect(x: 427, y: 220, width: 170, height: 170)))
    heat.draw(in: mercury, angle: -90)

    // Scale ticks to the right of the tube.
    NSColor(white: 1, alpha: 0.55).setFill()
    for (i, y) in stride(from: 470, through: 730, by: 65).enumerated() {
        NSBezierPath(roundedRect: NSRect(x: 600, y: CGFloat(y), width: i % 2 == 0 ? 90 : 60, height: 22),
                     xRadius: 11, yRadius: 11).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: set)
try! fm.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"]
try! p.run()
p.waitUntilExit()
try! draw(1024).write(to: URL(fileURLWithPath: "docs/icon.png"))
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
