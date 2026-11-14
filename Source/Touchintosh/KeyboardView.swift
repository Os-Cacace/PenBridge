// Draws the on-screen keyboard: handle strip, suggestion bar, keys, iOS-style key
// pop-ups, the long-press accent bubble and the glide trail. The view covers the whole
// panel; its top part is transparent room for pop-ups, and the glass sits behind the
// bottom part.
import AppKit

struct KBGeometry {
    var width = 0.0, height = 0.0, popupRoom = 0.0, corner = 0.0
    var pad = 0.0, strip = 0.0, bar = 0.0, row = 0.0, gapX = 0.0, gapY = 0.0
}

final class KeyboardView: NSView {
    struct Key { let spec: KeySpec; let slot: CGRect; let rect: CGRect }

    unowned let controller: KeyboardController
    private(set) var keys: [Key] = []
    private(set) var unit = 1.0
    private var g = KBGeometry()
    private var rowCount = 4
    private var fading: (path: [CGPoint], times: [Double], end: Double)?
    private var fadeTimer: Timer?
    var rowHeight: Double { g.row }

    init(controller: KeyboardController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func geometry(screenWidth: Double, scale: Double, layout: KeyboardLayout) -> KBGeometry {
        var x = KBGeometry()
        let s = max(0.6, min(scale, 1.5))
        let rows = layout.rows.count
        // Wider layouts get a wider keyboard so keys stay about the same size.
        let base = 1100 * max(1, layout.units / 11.5) * (layout.units > 13 ? 0.88 : 1)
        x.width = min(screenWidth - 12, base * s)
        x.pad = 8 * s
        x.strip = 22 * s
        x.bar = 40 * s
        x.row = (rows >= 5 ? 58 : 64) * s
        x.gapX = 8 * s
        x.gapY = (rows >= 5 ? 9 : 10) * s
        x.height = x.pad * 2 + x.strip + x.bar + x.row * Double(rows)
        x.popupRoom = x.row * 1.4
        x.corner = 26 * s
        g = x
        return x
    }

    private var top: Double { g.popupRoom }              // the keyboard's top edge in this view
    private var barTop: Double { top + g.pad + g.strip }
    private var rowsTop: Double { barTop + g.bar }

    /// Lays the keys out for the current language, page and options.
    func rebuild() {
        let layout = controller.layout
        rowCount = layout.rows.count
        let inner = g.width - g.pad * 2
        unit = inner / layout.units
        var out: [Key] = []
        for (r, row) in layout.rows.enumerated() {
            let rowUnits = row.reduce(0) { $0 + $1.width }
            var x = g.pad + (inner - rowUnits * unit) / 2
            let y = rowsTop + Double(r) * g.row
            for spec in row {
                let slot = CGRect(x: x, y: y, width: spec.width * unit, height: g.row)
                out.append(Key(spec: spec, slot: slot, rect: slot.insetBy(dx: g.gapX / 2, dy: g.gapY / 2)))
                x += spec.width * unit
            }
        }
        keys = out
        needsDisplay = true
    }

    // MARK: Hit testing

    func keyIndex(at p: CGPoint) -> Int? {
        guard !keys.isEmpty else { return nil }
        let r = min(max(Int((p.y - rowsTop) / g.row), 0), rowCount - 1)
        let y = rowsTop + (Double(r) + 0.5) * g.row
        var best: Int?, bestD = Double.infinity
        for (i, k) in keys.enumerated() where abs(k.slot.midY - y) < 1 {
            if case .spacer = k.spec.kind { continue }
            if k.slot.minX <= p.x && p.x < k.slot.maxX { return i }
            let d = min(abs(k.slot.minX - p.x), abs(k.slot.maxX - p.x))
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    func suggestionSlot(at p: CGPoint) -> Int? {
        guard p.y >= barTop && p.y < rowsTop - g.gapY / 2 else { return nil }
        let inner = g.width - g.pad * 2
        return min(max(Int((p.x - g.pad) / (inner / 3)), 0), 2)
    }

    /// The shortcut bar: the group button on the left, then the group's shortcuts.
    private func shortcutRects() -> [(Int, CGRect)] {
        let inner = g.width - g.pad * 2
        let y = barTop, h = g.bar - g.gapY / 2
        let groupW = max(inner * 0.11, 70)
        let list = shortcuts(controller.shortcutGroup)
        let w = (inner - groupW) / Double(max(list.count, 1))
        var out = [(-1, CGRect(x: g.pad, y: y, width: groupW, height: h))]
        for i in list.indices { out.append((i, CGRect(x: g.pad + groupW + Double(i) * w, y: y, width: w, height: h))) }
        return out
    }

    func shortcutSlot(at p: CGPoint) -> Int? {
        guard p.y >= barTop && p.y < rowsTop - g.gapY / 2 else { return nil }
        return shortcutRects().first { $0.1.minX <= p.x && p.x < $0.1.maxX }?.0
            ?? (p.x < g.pad ? -1 : shortcuts(controller.shortcutGroup).count - 1)
    }

    private var stripRect: CGRect { CGRect(x: 0, y: top, width: g.width, height: g.pad + g.strip) }
    private var buttonSize: Double { g.strip * 2.2 }
    private func stripButtons() -> [(StripControl, CGRect)] {
        let r = stripRect, b = buttonSize
        var out: [(StripControl, CGRect)] = [
            (.resize, CGRect(x: r.maxX - b - g.pad, y: r.minY, width: b, height: r.height)),
            (.advanced, CGRect(x: r.maxX - 2 * b - g.pad, y: r.minY, width: b, height: r.height)),
        ]
        if controller.floating { out.append((.dock, CGRect(x: g.pad, y: r.minY, width: b, height: r.height))) }
        return out
    }

    /// The handle strip along the top edge: buttons at the sides, the rest moves the keyboard.
    func stripControl(at p: CGPoint) -> StripControl? {
        guard stripRect.contains(p) else { return nil }
        return stripButtons().first { $0.1.contains(p) }?.0 ?? .move
    }

    func letterCenters() -> [Character: CGPoint] {
        var out: [Character: CGPoint] = [:]
        for k in keys {
            guard let t = k.spec.text, t.count == 1, let c = t.first, c.isLetter else { continue }
            out[c] = CGPoint(x: k.slot.midX, y: k.slot.midY)
        }
        return out
    }

    private func bubbleRect(for k: Key, count: Int) -> (rect: CGRect, item: Double) {
        let item = max(k.rect.width, unit * 0.95)
        let w = item * Double(count) + 12
        let h = k.rect.height * 1.05
        var x = k.rect.minX - 6
        x = min(max(x, 4), bounds.width - w - 4)
        return (CGRect(x: x, y: k.rect.minY - h - 8, width: w, height: h), item)
    }

    func alternateIndex(for key: Int, at p: CGPoint, count: Int) -> Int {
        let b = bubbleRect(for: keys[key], count: count)
        return min(max(Int((p.x - b.rect.minX - 6) / b.item), 0), count - 1)
    }

    func fadeTrail(_ path: [CGPoint]) {
        let now = CACurrentMediaTime()
        fading = (path, Array(repeating: now, count: path.count), now)
        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if CACurrentMediaTime() - (self.fading?.end ?? 0) > 0.28 { self.fading = nil; t.invalidate() }
            self.needsDisplay = true
        }
    }

    // MARK: Colours

    private var dark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    private var letterFill: NSColor { dark ? NSColor(white: 1, alpha: 0.24) : NSColor(white: 1, alpha: 0.82) }
    private var specialFill: NSColor { dark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0.45, alpha: 0.28) }
    private var popupFill: NSColor { dark ? NSColor(white: 0.42, alpha: 1) : NSColor(white: 1, alpha: 1) }
    private var ink: NSColor { dark ? .white : .black }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let now = CACurrentMediaTime()
        let contacts = controller.activeContacts
        let cursorMode = contacts.contains { if case .spaceCursor = $0.mode { return true }; return false }
        var pressed = Set<Int>(), popupKey: Int?, alternatesFor: (Int, Int)?
        var glides: [KeyContact] = []
        var heldStrip: StripControl?
        for c in contacts {
            if let k = c.key, k >= keys.count { continue }
            switch c.mode {
            case .tap:
                if let k = c.key {
                    if keys[k].spec.isLetterKey && controller.modifiers.isEmpty { popupKey = k } else { pressed.insert(k) }
                }
            case .alternates: if let k = c.key { alternatesFor = (k, c.altIndex) }
            case .special, .deleteRepeat, .spaceHold, .spaceCursor: if let k = c.key { pressed.insert(k) }
            case .glide: glides.append(c)
            case .move: heldStrip = .move
            case .resize: heldStrip = .resize
            case .strip(let s): heldStrip = s
            default: break
            }
        }
        if !glides.isEmpty { popupKey = nil }

        drawStrip(held: heldStrip)
        drawSuggestions(contacts)
        for (i, k) in keys.enumerated() {
            if case .spacer = k.spec.kind { continue }
            drawKey(k, pressed: pressed.contains(i), dim: cursorMode && k.spec.kind != .space)
        }
        if let k = popupKey { drawPopup(keys[k]) }
        if let (k, sel) = alternatesFor { drawAlternates(keys[k], selected: sel) }
        for c in glides { drawTrail(c.path, c.times, now: now, ended: nil) }
        if let f = fading { drawTrail(f.path, f.times, now: now, ended: f.end) }
    }

    private func drawStrip(held: StripControl?) {
        let r = stripRect
        // Grabber pill in the middle, like iPadOS's floating keyboard.
        let pill = CGRect(x: r.midX - 28, y: r.midY - 2.5 + g.pad * 0.3, width: 56, height: 5)
        (held == .move ? NSColor.controlAccentColor : ink.withAlphaComponent(0.35)).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 2.5, yRadius: 2.5).fill()
        for (control, rect) in stripButtons() {
            let symbol: String
            var active = held == control
            switch control {
            case .resize: symbol = "arrow.up.left.and.arrow.down.right"
            case .advanced: symbol = "command"; active = active || controller.advanced
            case .dock: symbol = "rectangle.bottomthird.inset.filled"
            case .move: continue
            }
            if active {
                specialFill.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 2).offsetBy(dx: 0, dy: g.pad * 0.3), xRadius: 8, yRadius: 8).fill()
            }
            drawSymbol(symbol, in: rect.offsetBy(dx: 0, dy: g.pad * 0.3), size: g.strip * 0.55,
                       color: active ? .controlAccentColor : ink.withAlphaComponent(0.6))
        }
    }

    private func drawShortcuts(_ contacts: [KeyContact]) {
        var held: Int?
        for c in contacts { if case .shortcut(let i) = c.mode { held = i } }
        let list = shortcuts(controller.shortcutGroup)
        let size = g.bar * 0.34
        for (i, r) in shortcutRects() {
            if held == i {
                specialFill.setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 3, dy: 2), xRadius: 10, yRadius: 10).fill()
            }
            if i < 0 {
                // The group name with a swap mark, in the accent colour, like a menu button.
                drawSymbolAndText("chevron.up.chevron.down", controller.shortcutGroup.title, in: r, size: size,
                                  weight: .semibold, color: .controlAccentColor, symbolFirst: false)
                continue
            }
            NSColor.separatorColor.setFill()
            NSRect(x: r.minX, y: r.midY - r.height * 0.25, width: 1, height: r.height * 0.5).fill()
            drawSymbolAndText(list[i].symbol, list[i].title, in: r, size: size, weight: .regular, color: ink, symbolFirst: true)
        }
    }

    /// An SF Symbol and a short title side by side, centred; the title is dropped when it doesn't fit.
    private func drawSymbolAndText(_ symbol: String, _ title: String, in r: CGRect, size: Double,
                                   weight: NSFont.Weight, color: NSColor, symbolFirst: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        let textSize = (title as NSString).size(withAttributes: attrs)
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.95, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        let imgSize = img?.size ?? .zero
        let gap = img == nil ? 0 : size * 0.35
        let showText = imgSize.width + gap + textSize.width <= r.width - 8 || img == nil
        let total = imgSize.width + (showText ? gap + textSize.width : 0)
        var x = r.midX - total / 2
        func drawImage() {
            guard let img else { return }
            img.draw(in: CGRect(x: x, y: r.midY - imgSize.height / 2, width: imgSize.width, height: imgSize.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += imgSize.width + (showText ? gap : 0)
        }
        func drawTitle() {
            guard showText else { return }
            (title as NSString).draw(at: CGPoint(x: x, y: r.midY - textSize.height / 2), withAttributes: attrs)
            x += textSize.width + gap
        }
        if symbolFirst { drawImage(); drawTitle() } else { drawTitle(); drawImage() }
    }

    private func drawSuggestions(_ contacts: [KeyContact]) {
        let s = controller.suggestions
        guard s.contains(where: { !$0.isEmpty }) else { drawShortcuts(contacts); return }
        let inner = g.width - g.pad * 2, w = inner / 3
        let barRect = CGRect(x: g.pad, y: barTop, width: inner, height: g.bar - g.gapY / 2)
        var held: Int?
        for c in contacts { if case .suggestion(let i) = c.mode { held = i } }
        for i in 0..<3 {
            let r = CGRect(x: barRect.minX + Double(i) * w, y: barRect.minY, width: w, height: barRect.height)
            if held == i {
                specialFill.setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 4, dy: 2), xRadius: 10, yRadius: 10).fill()
            }
            if i > 0 {
                NSColor.separatorColor.setFill()
                NSRect(x: r.minX, y: r.midY - r.height * 0.25, width: 1, height: r.height * 0.5).fill()
            }
            guard !s[i].isEmpty else { continue }
            let font = NSFont.systemFont(ofSize: g.bar * 0.42, weight: i == 1 ? .semibold : .regular)
            drawText(s[i], in: r, font: font, color: ink)
        }
    }

    private func drawKey(_ k: Key, pressed: Bool, dim: Bool) {
        let isLetter = k.spec.isLetterKey || k.spec.kind == .space
        var fill = isLetter ? letterFill : specialFill
        if pressed { fill = isLetter ? specialFill : letterFill }
        var accent = false
        switch k.spec.kind {
        case .shift: if controller.shift != .off { fill = letterFill }
        case .caps: accent = controller.shift == .locked
        case .modifier(let m): if controller.modifiers.contains(m) { fill = letterFill; accent = true }
        default: break
        }
        let radius = min(k.rect.height, k.rect.width) * 0.24
        let path = NSBezierPath(roundedRect: k.rect, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        if !dark {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.18)
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowBlurRadius = 0.5
            shadow.set()
        }
        fill.withAlphaComponent(fill.alphaComponent * (dim ? 0.35 : 1)).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        guard !dim else { return }
        let color: NSColor = accent ? .controlAccentColor : ink

        if let symbol = symbolName(for: k.spec) {
            drawSymbol(symbol, in: k.rect, size: k.rect.height * 0.32, color: color)
            return
        }
        let text = controller.label(for: k.spec)
        if let shifted = k.spec.shifted, k.spec.label == nil {
            // iPad style: the shift symbol small on top, the key's own character below.
            let shiftOn = controller.symbolShift
            let upper = k.rect.divided(atDistance: k.rect.height * 0.48, from: .minYEdge)
            // A lone haraka gets a dotted circle to sit on, or it would be nearly invisible.
            let mark = shifted.unicodeScalars.allSatisfy { $0.properties.generalCategory == .nonspacingMark }
            drawText(mark ? "◌" + shifted : shifted, in: upper.slice.offsetBy(dx: 0, dy: k.rect.height * 0.06),
                     font: NSFont.systemFont(ofSize: k.rect.height * 0.24), color: ink.withAlphaComponent(shiftOn ? 1 : 0.55))
            drawText(text, in: upper.remainder.offsetBy(dx: 0, dy: -k.rect.height * 0.06),
                     font: NSFont.systemFont(ofSize: k.rect.height * 0.30, weight: .light), color: ink.withAlphaComponent(shiftOn ? 0.55 : 1))
            return
        }
        let small = k.spec.label != nil || text.count > 2
        let size = small ? k.rect.height * 0.25 : k.rect.height * (controller.language == .ar ? 0.42 : 0.40)
        drawText(text, in: k.rect, font: NSFont.systemFont(ofSize: size, weight: small ? .regular : .light), color: color)
    }

    private func symbolName(for spec: KeySpec) -> String? {
        switch spec.kind {
        case .shift:
            switch controller.shift { case .off: return "shift"; case .once: return "shift.fill"; case .locked: return "capslock.fill" }
        case .caps: return controller.shift == .locked ? "capslock.fill" : "capslock"
        case .delete: return "delete.left"
        case .ret: return "return"
        case .globe: return "globe"
        case .hide: return "keyboard.chevron.compact.down"
        case .arrow(let code):
            switch code { case 123: return "arrowtriangle.left.fill"; case 124: return "arrowtriangle.right.fill"
            case 125: return "arrowtriangle.down.fill"; default: return "arrowtriangle.up.fill" }
        default: return nil
        }
    }

    private func drawPopup(_ k: Key) {
        let key = k.rect
        let headW = max(key.width * 1.45, unit * 1.3), headH = key.height * 1.15, neck = key.height * 0.2
        var head = CGRect(x: key.midX - headW / 2, y: key.minY - neck - headH, width: headW, height: headH)
        head.origin.x = min(max(head.minX, 2), bounds.width - headW - 2)
        let r = key.height * 0.22, hr = headH * 0.26
        let p = CGMutablePath()
        // Flipped coordinates: down is +y. Start at the key's bottom-left, go clockwise.
        p.move(to: CGPoint(x: key.minX, y: key.maxY - r))
        p.addLine(to: CGPoint(x: key.minX, y: key.minY))
        p.addCurve(to: CGPoint(x: head.minX, y: head.maxY - hr * 0.6),
                   control1: CGPoint(x: key.minX, y: key.minY - neck * 0.6),
                   control2: CGPoint(x: head.minX, y: head.maxY))
        p.addLine(to: CGPoint(x: head.minX, y: head.minY + hr))
        p.addQuadCurve(to: CGPoint(x: head.minX + hr, y: head.minY), control: CGPoint(x: head.minX, y: head.minY))
        p.addLine(to: CGPoint(x: head.maxX - hr, y: head.minY))
        p.addQuadCurve(to: CGPoint(x: head.maxX, y: head.minY + hr), control: CGPoint(x: head.maxX, y: head.minY))
        p.addLine(to: CGPoint(x: head.maxX, y: head.maxY - hr * 0.6))
        p.addCurve(to: CGPoint(x: key.maxX, y: key.minY),
                   control1: CGPoint(x: head.maxX, y: head.maxY),
                   control2: CGPoint(x: key.maxX, y: key.minY - neck * 0.6))
        p.addLine(to: CGPoint(x: key.maxX, y: key.maxY - r))
        p.addQuadCurve(to: CGPoint(x: key.maxX - r, y: key.maxY), control: CGPoint(x: key.maxX, y: key.maxY))
        p.addLine(to: CGPoint(x: key.minX + r, y: key.maxY))
        p.addQuadCurve(to: CGPoint(x: key.minX, y: key.maxY - r), control: CGPoint(x: key.minX, y: key.maxY))
        p.closeSubpath()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: NSColor(white: 0, alpha: 0.3).cgColor)
        ctx.addPath(p)
        ctx.setFillColor(popupFill.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        let text = controller.output(for: k.spec) ?? controller.label(for: k.spec)
        drawText(text, in: head.offsetBy(dx: 0, dy: -headH * 0.04),
                 font: NSFont.systemFont(ofSize: headH * 0.55, weight: .regular), color: ink)
    }

    private func drawAlternates(_ k: Key, selected: Int) {
        let alts = controller.alternates(for: k.spec).map(controller.applyShift)
        let b = bubbleRect(for: k, count: alts.count)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 8, color: NSColor(white: 0, alpha: 0.3).cgColor)
        popupFill.setFill()
        NSBezierPath(roundedRect: b.rect, xRadius: 14, yRadius: 14).fill()
        ctx.restoreGState()
        for (i, a) in alts.enumerated() {
            let r = CGRect(x: b.rect.minX + 6 + Double(i) * b.item, y: b.rect.minY + 5, width: b.item, height: b.rect.height - 10)
            if i == selected {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 0), xRadius: 10, yRadius: 10).fill()
            }
            drawText(a, in: r, font: NSFont.systemFont(ofSize: r.height * 0.5), color: i == selected ? .white : ink)
        }
    }

    private func drawTrail(_ path: [CGPoint], _ times: [Double], now: Double, ended: Double?) {
        guard path.count > 1, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let life = 0.55
        let fadeOut = ended.map { max(0, 1 - (now - $0) / 0.28) } ?? 1
        ctx.saveGState()
        ctx.setLineCap(.round)
        let color = NSColor.controlAccentColor
        for i in 1..<path.count {
            let age = ended == nil ? now - times[i] : 0
            let a = max(0, 1 - age / life) * fadeOut
            guard a > 0.02 else { continue }
            ctx.setStrokeColor(color.withAlphaComponent(0.85 * a).cgColor)
            ctx.setLineWidth(max(2, g.row * 0.11 * (0.4 + 0.6 * a)))
            ctx.move(to: path[i - 1]); ctx.addLine(to: path[i])
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private func drawText(_ s: String, in r: CGRect, font: NSFont, color: NSColor) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        let size = (s as NSString).size(withAttributes: attrs)
        let rect = CGRect(x: r.minX + 4, y: r.midY - size.height / 2, width: r.width - 8, height: size.height)
        (s as NSString).draw(in: rect, withAttributes: attrs)
    }

    private func drawSymbol(_ name: String, in r: CGRect, size: Double, color: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let s = img.size
        img.draw(in: CGRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height),
                 from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
