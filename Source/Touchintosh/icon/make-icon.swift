// Renders the Touchintosh app icon: a Mac desktop on a touchscreen, tapped by a fingertip.
// Usage: swift make-icon.swift out.png
import AppKit
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(colorSpace: space, components: [r, g, b, a])! }
func linear(_ colors: [CGColor], from: CGPoint, to: CGPoint) {
    ctx.drawLinearGradient(CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
func radial(_ colors: [CGColor], at c: CGPoint, radius: Double) {
    ctx.drawRadialGradient(CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!,
                           startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
}
func rounded(_ r: CGRect, _ radius: Double) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }
func fill(_ path: CGPath, _ c: CGColor) { ctx.addPath(path); ctx.setFillColor(c); ctx.fillPath() }

// macOS icon grid: 824 pt body inside the 1024 canvas, leaving room for the drop shadow.
let plate = rounded(CGRect(x: 100, y: 100, width: 824, height: 824), 185)
ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: color(0, 0, 0, 0.35))
fill(plate, color(0.15, 0.2, 0.5)); ctx.restoreGState()
ctx.saveGState(); ctx.addPath(plate); ctx.clip()
linear([color(0.93, 0.95, 1.0), color(0.80, 0.85, 0.95)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))

// The display: a dark bezel around a Mac desktop.
let bezel = CGRect(x: 168, y: 250, width: 688, height: 520)
ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 36, color: color(0.05, 0.08, 0.25, 0.45))
fill(rounded(bezel, 48), color(0.11, 0.12, 0.16)); ctx.restoreGState()
let desk = bezel.insetBy(dx: 24, dy: 24)
ctx.saveGState(); ctx.addPath(rounded(desk, 26)); ctx.clip()
// Wallpaper: a deep blue-violet sweep, like a macOS default.
linear([color(0.25, 0.55, 1.0), color(0.30, 0.22, 0.85), color(0.75, 0.25, 0.70)], from: CGPoint(x: desk.minX, y: desk.maxY), to: CGPoint(x: desk.maxX, y: desk.minY))
radial([color(1, 1, 1, 0.30), color(1, 1, 1, 0)], at: CGPoint(x: desk.minX + 120, y: desk.maxY - 60), radius: 420)
// Menu bar.
fill(CGPath(rect: CGRect(x: desk.minX, y: desk.maxY - 34, width: desk.width, height: 34), transform: nil), color(1, 1, 1, 0.30))
for (i, w) in [26.0, 46.0, 40.0, 52.0].enumerated() {
    let x = desk.minX + 22 + Double(i) * 64
    fill(rounded(CGRect(x: x, y: desk.maxY - 22, width: w, height: 10), 5), color(1, 1, 1, i == 0 ? 0.95 : 0.7))
}
// A window with the three traffic-light buttons.
let win = CGRect(x: desk.minX + 70, y: desk.minY + 120, width: 400, height: 250)
ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0, 0, 0.2, 0.4))
fill(rounded(win, 22), color(0.98, 0.98, 1.0)); ctx.restoreGState()
fill(CGPath(rect: CGRect(x: win.minX, y: win.maxY - 44, width: win.width, height: 1.5), transform: nil), color(0, 0, 0, 0.08))
for (i, c) in [color(1.0, 0.37, 0.34), color(1.0, 0.74, 0.18), color(0.16, 0.79, 0.25)].enumerated() {
    let x = win.minX + 30 + Double(i) * 34
    ctx.setFillColor(c); ctx.fillEllipse(in: CGRect(x: x - 11, y: win.maxY - 33, width: 22, height: 22))
}
for (i, w) in [300.0, 240.0, 270.0, 180.0].enumerated() {
    fill(rounded(CGRect(x: win.minX + 34, y: win.maxY - 90 - Double(i) * 38, width: w, height: 14), 7), color(0.2, 0.25, 0.4, 0.16))
}
// The Dock.
let dock = CGRect(x: desk.midX - 170, y: desk.minY + 16, width: 340, height: 74)
fill(rounded(dock, 24), color(1, 1, 1, 0.32))
let tiles = [color(0.20, 0.56, 1.0), color(1.0, 0.45, 0.30), color(0.25, 0.80, 0.45), color(1.0, 0.78, 0.25), color(0.70, 0.40, 0.95)]
for (i, c) in tiles.enumerated() {
    fill(rounded(CGRect(x: dock.minX + 18 + Double(i) * 62, y: dock.minY + 12, width: 50, height: 50), 13), c)
}
ctx.restoreGState()

// Tap ripples where the fingertip meets the glass.
let touch = CGPoint(x: desk.maxX - 150, y: desk.midY + 10)
for (i, r) in [44.0, 78.0, 112.0].enumerated() {
    ctx.setStrokeColor(color(1, 1, 1, 0.95 - Double(i) * 0.3)); ctx.setLineWidth(9 - Double(i) * 2.5)
    ctx.strokeEllipse(in: CGRect(x: touch.x - r, y: touch.y - r, width: r * 2, height: r * 2))
}
radial([color(1, 1, 1, 0.85), color(1, 1, 1, 0)], at: touch, radius: 40)

// The fingertip: an index finger coming in from the lower right.
ctx.saveGState()
ctx.translateBy(x: touch.x + 6, y: touch.y - 12); ctx.rotate(by: 32 * .pi / 180)
let fw = 112.0, fl = 520.0
let finger = rounded(CGRect(x: -fw / 2, y: -fl, width: fw, height: fl), fw / 2)
ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 10, height: -18), blur: 30, color: color(0.05, 0.05, 0.2, 0.45))
fill(finger, color(1.0, 0.80, 0.66)); ctx.restoreGState()
ctx.saveGState(); ctx.addPath(finger); ctx.clip()
linear([color(1.0, 0.86, 0.74), color(0.98, 0.74, 0.60), color(0.90, 0.60, 0.48)], from: CGPoint(x: -fw / 2, y: 0), to: CGPoint(x: fw / 2, y: 0))
// Knuckle crease and nail.
ctx.setStrokeColor(color(0.75, 0.45, 0.35, 0.45)); ctx.setLineWidth(4)
ctx.move(to: CGPoint(x: -fw / 2 + 22, y: -215)); ctx.addQuadCurve(to: CGPoint(x: fw / 2 - 22, y: -215), control: CGPoint(x: 0, y: -228)); ctx.strokePath()
fill(rounded(CGRect(x: -fw / 2 + 24, y: -130, width: fw - 48, height: 92), 30), color(1.0, 0.92, 0.88))
fill(rounded(CGRect(x: -fw / 2 + 34, y: -122, width: 16, height: 70), 8), color(1, 1, 1, 0.7))
ctx.restoreGState()
ctx.restoreGState()
ctx.restoreGState()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
