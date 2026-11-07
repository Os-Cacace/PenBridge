// Renders docs/images/banner.png (README header and GitHub social preview) from the
// app icon and the panel screenshots. Run from the repo root:
//   swift Source/docs/make-banner.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let images = root.appendingPathComponent("docs/images")
let scale: CGFloat = 2
let size = NSSize(width: 1280, height: 640)

func load(_ path: String) -> NSImage {
    guard let image = NSImage(contentsOf: root.appendingPathComponent(path)) else { fatalError("missing \(path)") }
    return image
}

let icon = load("Source/PenBridge/icon/AppIcon-1024.png")
let shots = [load("docs/images/panel-Pen.png"), load("docs/images/panel-Buttons.png")]

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Background: deep blue to violet, with a soft glow behind the screenshots.
NSGradient(colors: [NSColor(srgbRed: 0.05, green: 0.07, blue: 0.16, alpha: 1),
                    NSColor(srgbRed: 0.16, green: 0.09, blue: 0.30, alpha: 1)])!
    .draw(in: NSRect(origin: .zero, size: size), angle: -20)
NSGradient(colors: [NSColor(srgbRed: 0.25, green: 0.45, blue: 1, alpha: 0.35), .clear])!
    .draw(fromCenter: NSPoint(x: 960, y: 320), radius: 0, toCenter: NSPoint(x: 960, y: 320), radius: 420, options: [])

// Left: icon, name, tagline, feature chips.
icon.draw(in: NSRect(x: 72, y: 448, width: 120, height: 120))
func text(_ s: String, _ font: NSFont, _ color: NSColor, at p: NSPoint, width: CGFloat = 640) {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 4
    let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    // p is the top-left corner of the text block.
    let h = ceil(a.boundingRect(with: NSSize(width: width, height: 1000), options: [.usesLineFragmentOrigin]).height)
    a.draw(with: NSRect(x: p.x, y: p.y - h, width: width, height: h), options: [.usesLineFragmentOrigin])
}
text("PenBridge", .systemFont(ofSize: 76, weight: .bold), .white, at: NSPoint(x: 76, y: 440))
text("Pen pressure, tilt, configurable pen buttons and touch gestures for Hackintosh touchscreens.",
     .systemFont(ofSize: 26, weight: .regular), NSColor(white: 1, alpha: 0.78), at: NSPoint(x: 80, y: 330), width: 560)

var x: CGFloat = 80, y: CGFloat = 170
for chip in ["Pressure & tilt", "Per-app pen buttons", "Touch gestures", "Guided installer", "Claude helper"] {
    let font = NSFont.systemFont(ofSize: 17, weight: .semibold)
    let w = (chip as NSString).size(withAttributes: [.font: font]).width + 28
    if x + w > 660 { x = 80; y -= 46 }
    let r = NSRect(x: x, y: y, width: w, height: 34)
    NSColor(white: 1, alpha: 0.12).setFill()
    NSBezierPath(roundedRect: r, xRadius: 17, yRadius: 17).fill()
    NSAttributedString(string: chip, attributes: [.font: font, .foregroundColor: NSColor.white])
        .draw(at: NSPoint(x: r.minX + 14, y: r.minY + 7))
    x += w + 10
}

// Right: two panel screenshots, cropped to their top part, with shadows.
func drawShot(_ image: NSImage, in rect: NSRect) {
    // Crop the top of the screenshot to the frame's aspect ratio (never past its bottom).
    let cropHeight = min(image.size.height, image.size.width * rect.height / rect.width)
    let source = NSRect(x: 0, y: image.size.height - cropHeight, width: image.size.width, height: cropHeight)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowColor = NSColor(white: 0, alpha: 0.55)
    shadow.set()
    let path = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    image.draw(in: rect, from: source, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    NSColor(white: 1, alpha: 0.18).setStroke()
    path.lineWidth = 1
    path.stroke()
}
drawShot(shots[0], in: NSRect(x: 700, y: 90, width: 290, height: 440))
drawShot(shots[1], in: NSRect(x: 920, y: 60, width: 300, height: 480))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: images.appendingPathComponent("banner.png"))
print("wrote docs/images/banner.png")
