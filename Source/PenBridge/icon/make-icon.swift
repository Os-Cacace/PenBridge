// Renders the PenBridge app icon: a glass stylus drawing a pressure stroke.
// Usage: swift make-icon.swift out.png
import AppKit
let size = 1024.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(colorSpace: space, components: [r, g, b, a])! }
func linear(_ colors: [CGColor], from: CGPoint, to: CGPoint) {
    ctx.drawLinearGradient(CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
// macOS icon grid: 824 pt body inside the 1024 canvas, leaving room for the drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let plate = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185).cgPath
ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: color(0, 0, 0, 0.35))
ctx.addPath(plate); ctx.setFillColor(color(0.2, 0.3, 0.8)); ctx.fillPath(); ctx.restoreGState()
ctx.saveGState(); ctx.addPath(plate); ctx.clip()
linear([color(0.36, 0.72, 1.0), color(0.20, 0.36, 0.93), color(0.27, 0.15, 0.72)], from: CGPoint(x: 300, y: 924), to: CGPoint(x: 720, y: 100))
ctx.drawRadialGradient(CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.42), color(1, 1, 1, 0)] as CFArray, locations: nil)!,
                       startCenter: CGPoint(x: 330, y: 860), startRadius: 0, endCenter: CGPoint(x: 330, y: 860), endRadius: 560, options: [])
// The stroke: width grows along the curve, as if pressing harder.
func cubic(_ t: Double) -> CGPoint {
    let p0 = CGPoint(x: 780, y: 245), p1 = CGPoint(x: 610, y: 150), p2 = CGPoint(x: 420, y: 330), p3 = CGPoint(x: 285, y: 262)
    let u = 1 - t, a = u*u*u, b = 3*u*u*t, c = 3*u*t*t, d = t*t*t
    return CGPoint(x: a*p0.x + b*p1.x + c*p2.x + d*p3.x, y: a*p0.y + b*p1.y + c*p2.y + d*p3.y)
}
ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: color(0.05, 0.05, 0.35, 0.45))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setFillColor(color(1, 1, 1, 0.96))
for i in 0...400 { let t = Double(i) / 400, p = cubic(t), r = 3 + 25 * sin(t * .pi * 0.86 + 0.14)
    ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)) }
ctx.endTransparencyLayer(); ctx.restoreGState()
// The stylus, drawn upright then turned to point at the start of the stroke.
ctx.saveGState()
ctx.translateBy(x: 285, y: 262); ctx.rotate(by: -40 * .pi / 180)
let w = 148.0, tipLen = 182.0, barrel = 520.0
let outline = CGMutablePath()
outline.move(to: .zero)
outline.addLine(to: CGPoint(x: -w/2, y: tipLen))
outline.addLine(to: CGPoint(x: -w/2, y: tipLen + barrel - 58))
outline.addQuadCurve(to: CGPoint(x: -w/2 + 58, y: tipLen + barrel), control: CGPoint(x: -w/2, y: tipLen + barrel))
outline.addLine(to: CGPoint(x: w/2 - 58, y: tipLen + barrel))
outline.addQuadCurve(to: CGPoint(x: w/2, y: tipLen + barrel - 58), control: CGPoint(x: w/2, y: tipLen + barrel))
outline.addLine(to: CGPoint(x: w/2, y: tipLen))
outline.closeSubpath()
ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 14, height: -20), blur: 42, color: color(0.03, 0.03, 0.3, 0.55))
ctx.addPath(outline); ctx.setFillColor(color(1, 1, 1, 0.2)); ctx.fillPath(); ctx.restoreGState()
ctx.saveGState(); ctx.addPath(outline); ctx.clip()
linear([color(1, 1, 1, 0.62), color(1, 1, 1, 0.16), color(1, 1, 1, 0.34)], from: CGPoint(x: -w/2, y: 0), to: CGPoint(x: w/2, y: 0))
// Solid nib, with the glass barrel above it.
ctx.saveGState(); ctx.clip(to: CGRect(x: -w, y: 0, width: w * 2, height: tipLen))
linear([color(1, 1, 1, 1), color(0.86, 0.92, 1, 1)], from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: tipLen)); ctx.restoreGState()
ctx.setFillColor(color(1, 1, 1, 0.55)); ctx.fill(CGRect(x: -w, y: tipLen - 3, width: w * 2, height: 6))
// Specular streak down the lit side.
ctx.setFillColor(color(1, 1, 1, 0.75))
ctx.addPath(CGPath(roundedRect: CGRect(x: -w/2 + 18, y: tipLen + 46, width: 15, height: barrel - 150), cornerWidth: 7.5, cornerHeight: 7.5, transform: nil)); ctx.fillPath()
ctx.restoreGState()
ctx.addPath(outline); ctx.setStrokeColor(color(1, 1, 1, 0.82)); ctx.setLineWidth(5); ctx.strokePath()
ctx.restoreGState()
// Glass rim on the plate.
ctx.restoreGState()
ctx.saveGState(); ctx.addPath(plate); ctx.clip()
ctx.addPath(plate); ctx.replacePathWithStrokedPath(); ctx.clip()
_ = 0
ctx.restoreGState()
ctx.saveGState(); ctx.addPath(NSBezierPath(roundedRect: body.insetBy(dx: 3, dy: 3), xRadius: 182, yRadius: 182).cgPath)
ctx.setLineWidth(5); ctx.replacePathWithStrokedPath(); ctx.clip()
linear([color(1, 1, 1, 0.75), color(1, 1, 1, 0.08), color(1, 1, 1, 0.22)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
ctx.restoreGState()
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
