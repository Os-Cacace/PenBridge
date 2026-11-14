// On-screen keyboard: an iPad-style glass keyboard on the built-in panel. It never
// takes focus: touch and pen reach it from the digitizer reports (see KeyboardRouter
// in KeyboardInput.swift), and it types by posting key events carrying Unicode text,
// so it works whatever input source macOS has selected. With a modifier held
// (Advanced layout) it sends US key codes instead, so shortcuts work.
//
// Features: key pop-ups, long-press accents, glide typing with a fading trail,
// suggestions, shift / caps lock, auto-capitalisation, smart spaces, double-space
// period, space-bar cursor control, backspace repeat, English and Arabic, a number
// row, an Advanced Mac layout, and a handle strip to move, resize and dock it.
import AppKit

enum ShiftState { case off, once, locked }
enum StripControl { case move, resize, advanced, dock }

/// One finger, pen tip or mouse press on the keyboard.
struct KeyContact {
    enum Mode {
        case tap, glide, alternates, spaceHold, spaceCursor, deleteRepeat, special, suggestion(Int)
        case shortcut(Int)         // a shortcut bar slot; -1 is the group button
        case move, resize, strip(StripControl), consumed
    }
    var mode: Mode
    var start: CGPoint
    var current: CGPoint
    var startGlobal: CGPoint
    var began: Double
    var key: Int?                  // index into the view's keys
    var path: [CGPoint] = []
    var times: [Double] = []
    var altIndex = 0
    var cursorRest = CGPoint.zero
    var startOrigin = CGPoint.zero
    var startScale = 1.0
    var timer: Timer?
}

final class KeyboardController {
    static let shared = KeyboardController()

    private(set) var visible = false
    private var autoShown = false
    private var panel: NSPanel?
    private var glass: NSView?             // Liquid Glass on macOS 26, a blur before that
    private var glassCorner = 0.0
    private var view: KeyboardView?

    var language: KeyLanguage = KeyLanguage(rawValue: UserDefaults.standard.string(forKey: "keyboardLanguage") ?? "") ?? .en {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "keyboardLanguage") }
    }
    var page: KeyPage = .letters
    var shift: ShiftState = .off { didSet { scheduleHold() } }
    private var shiftIsAuto = false {      // set by auto-capitals, so digits still type digits
        didSet { scheduleHold() }
    }
    private(set) var modifiers = Set<Modifier>() { didSet { scheduleHold() } }
    private var heldNow: CGEventFlags = []  // the real modifier keys pressed for the lit ones
    private var holdScheduled = false
    private var lockedModifiers = Set<Modifier>()
    private var lastModifierTap: [Modifier: Double] = [:]
    private var lastShiftTap = 0.0
    private var lexicons: [KeyLanguage: Lexicon] = [:]
    private var loading = Set<KeyLanguage>()
    private var generating = Set<KeyLanguage>()
    private var contacts: [Int: KeyContact] = [:]

    // What Touchintosh typed since the context was last known, used for auto-capitals,
    // smart spaces and suggestions. Reset when the user clicks or taps elsewhere.
    private var context = ""
    private var contextKnown = false
    private var smartSpace = false          // the last character is a space Touchintosh added
    private var lastGlide: (word: String, typed: String, alternatives: [String])?
    private var lastSpaceTime = 0.0
    private(set) var suggestions: [String] = ["", "", ""]

    var shortcutGroup: ShortcutGroup = ShortcutGroup(rawValue: UserDefaults.standard.integer(forKey: "keyboardShortcutGroup")) ?? .edit {
        didSet { UserDefaults.standard.set(shortcutGroup.rawValue, forKey: "keyboardShortcutGroup") }
    }
    /// The bar shows shortcuts whenever there is no word to suggest.
    var showsShortcuts: Bool { suggestions.allSatisfy { $0.isEmpty } }

    private var cfgKB: Config { settingsModel.c }
    private var placeAtTop = false
    private var liveScale: Double?          // while resizing
    private var hiddenForElement: Int?      // hidden by hand while this field had focus
    private var focusCheck: DispatchWorkItem?

    var advanced: Bool { cfgKB.keyboardAdvanced }
    var floating: Bool { cfgKB.keyboardX >= 0 }
    var scale: Double { liveScale ?? cfgKB.keyboardSize }
    var layout: KeyboardLayout {
        keyboardLayout(language, page, numberRow: cfgKB.keyboardNumberRow, advanced: advanced)
    }

    // MARK: Showing

    func toggle() { visible ? hide(byUser: true) : show(auto: false) }

    func show(auto: Bool) {
        if visible { if !auto { autoShown = false }; return }
        autoShown = auto
        if !auto { hiddenForElement = nil }
        placeAtTop = focusedFieldIsLow()
        buildPanelIfNeeded()
        loadLexicon(language)
        guard let panel else { return }
        visible = true
        contextKnown = false
        page = .letters
        refreshShiftAuto()
        layoutPanel()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        publishFrame()
        log("Touchintosh: keyboard shown\(auto ? " (text field)" : "")")
    }

    func hide(byUser: Bool = false) {
        guard visible, let panel else { return }
        if byUser { hiddenForElement = focusedElement().map { Int(CFHash($0)) } }
        visible = false
        autoShown = false
        for (_, c) in contacts { c.timer?.invalidate() }
        contacts.removeAll()
        clearModifiers(includingLocked: true)
        keyboardShared.setFrame(.null)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            if self?.visible == false { panel.orderOut(nil) }
        })
        log("Touchintosh: keyboard hidden")
    }

    func hideIfAutoShown() { if autoShown { hide() } }

    /// Settings changed (size, layout, number row): redraw at the new size.
    func settingsChanged() {
        guard visible else { return }
        layoutPanel(); publishFrame()
    }

    /// Shows or hides the keyboard to match the focused element, as the show setting asks.
    /// fromTouch: the user just tapped with a finger or the pen.
    func scheduleFocusCheck(fromTouch: Bool) {
        let mode = cfgKB.keyboardShow
        guard mode == .textField || (mode == .touch && fromTouch) else { return }
        focusCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async {
                let el = focusedElement()
                let editable = el.map(isEditable) ?? false
                let id = el.map { Int(CFHash($0)) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    if editable {
                        if self.hiddenForElement != nil && self.hiddenForElement == id { return }
                        self.hiddenForElement = nil
                        self.show(auto: true)
                    } else {
                        self.hiddenForElement = nil
                        self.hideIfAutoShown()
                    }
                }
            }
        }
        focusCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// The built-in display, which is where the digitizer is.
    private func builtInScreen() -> NSScreen {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { CGDisplayIsBuiltin($0.uint32Value) != 0 } ?? false
        } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func buildPanelIfNeeded() {
        guard panel == nil else { return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 300),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.ignoresMouseEvents = true          // input comes through KeyboardRouter instead
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        let container = NSView()
        let g = makeGlass()
        let v = KeyboardView(controller: self)
        container.addSubview(g)
        container.addSubview(v)
        p.contentView = container
        panel = p; glass = g; view = v
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.visible else { return }
            self.layoutPanel(); self.publishFrame()
        }
    }

    private func makeGlass() -> NSView {
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.style = .regular
            return g
        }
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.masksToBounds = true
        return v
    }

    private func setGlassCorner(_ r: Double) {
        glassCorner = r
        if #available(macOS 26.0, *), let g = glass as? NSGlassEffectView { g.cornerRadius = r; return }
        glass?.layer?.cornerRadius = r
    }

    /// Sizes and places the panel, with transparent room above the keys for pop-ups.
    /// Docked: bottom centre (or top, when the text field is low on the screen).
    /// Floating: where it was dragged, kept on screen.
    private func layoutPanel(keepTopLeft: CGPoint? = nil) {
        guard let panel, let glass, let view else { return }
        let screen = builtInScreen()
        let g = view.geometry(screenWidth: screen.frame.width, scale: scale, layout: layout)
        let total = g.height + g.popupRoom
        var origin: CGPoint
        if let tl = keepTopLeft {
            origin = CGPoint(x: tl.x, y: tl.y - total)
        } else if floating {
            origin = CGPoint(x: screen.frame.minX + cfgKB.keyboardX, y: screen.frame.minY + cfgKB.keyboardY)
        } else {
            let atTop = placeAtTop && screen.visibleFrame.height > total * 2
            origin = CGPoint(x: screen.frame.midX - g.width / 2,
                             y: atTop ? screen.visibleFrame.maxY - total - 6 : screen.frame.minY + 6)
        }
        origin.x = min(max(origin.x, screen.frame.minX), screen.frame.maxX - g.width)
        origin.y = min(max(origin.y, screen.frame.minY), screen.frame.maxY - total)
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: g.width, height: total), display: false)
        glass.frame = NSRect(x: 0, y: 0, width: g.width, height: g.height)
        setGlassCorner(g.corner)
        view.frame = NSRect(x: 0, y: 0, width: g.width, height: total)
        view.rebuild()
    }

    /// Tells the input thread where the keys are, in global display coordinates.
    private func publishFrame() {
        guard visible, let panel, let glass else { keyboardShared.setFrame(.null); return }
        let r = panel.convertToScreen(glass.frame)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        keyboardShared.setFrame(CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height))
    }

    func toLocal(_ global: CGPoint) -> CGPoint {
        guard let panel, let view else { return .zero }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let screenPoint = NSPoint(x: global.x, y: primaryHeight - global.y)
        return view.convert(panel.convertPoint(fromScreen: screenPoint), from: nil)
    }

    // MARK: Lexicon

    private func loadLexicon(_ lang: KeyLanguage) {
        guard lexicons[lang] == nil, !loading.contains(lang) else { return }
        loading.insert(lang)
        DispatchQueue.global(qos: .userInitiated).async {
            let lex = Lexicon(language: lang.rawValue)
            DispatchQueue.main.async {
                self.lexicons[lang] = lex
                self.loading.remove(lang)
                log("Touchintosh: keyboard lexicon \(lang.rawValue) loaded, \(lex.words.count) words")
                // No word list yet (first use): build one from the spell checker, then reload.
                if lex.words.count < 1000 && !self.generating.contains(lang) {
                    self.generating.insert(lang)
                    log("Touchintosh: building the \(lang.rawValue) word list")
                    Lexicon.generate(lang.rawValue) { ok in
                        self.generating.remove(lang)
                        log("Touchintosh: \(lang.rawValue) word list \(ok ? "built" : "could not be built")")
                        guard ok else { return }
                        self.lexicons[lang] = nil
                        self.loadLexicon(lang)
                    }
                }
            }
        }
    }

    // MARK: Contacts (from KeyboardRouter, main thread)

    func contactBegan(_ id: Int, at global: CGPoint) {
        guard visible, let view, let panel else { return }
        let now = CACurrentMediaTime()
        // A mouse press that turned out to be the touchscreen: drop the mouse copy.
        if id != -1, let m = contacts[-1], now - m.began < 0.12 {
            m.timer?.invalidate(); contacts[-1] = nil
        }
        let p = toLocal(global)
        var c = KeyContact(mode: .consumed, start: p, current: p, startGlobal: global, began: now)
        c.path = [p]; c.times = [now]

        if let control = view.stripControl(at: p) {
            switch control {
            case .move: c.mode = .move; c.startOrigin = panel.frame.origin
            case .resize: c.mode = .resize; c.startScale = scale; c.startOrigin = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
            default: c.mode = .strip(control)
            }
            contacts[id] = c; view.needsDisplay = true
            return
        }
        if showsShortcuts, let slot = view.shortcutSlot(at: p) {
            c.mode = .shortcut(slot)
            contacts[id] = c; view.needsDisplay = true
            return
        }
        if let slot = view.suggestionSlot(at: p) {
            c.mode = .suggestion(slot)
            contacts[id] = c; view.needsDisplay = true
            return
        }
        guard let k = view.keyIndex(at: p) else { return }
        c.key = k
        // Typing fast with two fingers: the earlier tap counts as soon as the next one lands.
        for (other, var oc) in contacts where isTap(oc.mode) {
            oc.timer?.invalidate(); oc.timer = nil
            commitTap(oc)
            oc.mode = .consumed
            contacts[other] = oc
        }
        let spec = view.keys[k].spec
        switch spec.kind {
        case .delete:
            deleteBackward()
            c.mode = .deleteRepeat
            var repeats = 0
            c.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                guard let self else { return }
                let t = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
                    repeats += 1
                    if repeats > 12 { self?.deleteWordBackward() } else { self?.deleteBackward() }
                }
                self.contacts[id]?.timer = t
            }
        case .shift:
            switch shift {
            case .off: shift = .once
            case .once: shift = now - lastShiftTap < 0.35 && !shiftIsAuto ? .locked : .off
            case .locked: shift = .off
            }
            shiftIsAuto = false
            lastShiftTap = now
            c.mode = .consumed
        case .caps:
            shift = shift == .locked ? .off : .locked
            shiftIsAuto = false
            c.mode = .consumed
        case .modifier(let m):
            if lockedModifiers.contains(m) { lockedModifiers.remove(m); modifiers.remove(m) }
            else if modifiers.contains(m) {
                if now - (lastModifierTap[m] ?? 0) < 0.35 { lockedModifiers.insert(m) } else { modifiers.remove(m) }
            } else { modifiers.insert(m) }
            lastModifierTap[m] = now
            c.mode = .consumed
        case .arrow(let code):
            sendKeyCode(code, flags: modifierFlags(includeShift: true))
            contextKnown = false
            c.mode = .deleteRepeat   // held arrows repeat
            c.timer = repeatTimer(id) { [weak self] in
                self?.sendKeyCode(code, flags: self?.modifierFlags(includeShift: true) ?? [])
            }
        case .space:
            if !modifiers.isEmpty { c.mode = .special; break }
            c.mode = .spaceHold
            c.timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                guard let self, var cc = self.contacts[id], case .spaceHold = cc.mode else { return }
                cc.mode = .spaceCursor; cc.cursorRest = cc.current
                self.contacts[id] = cc
                self.view?.needsDisplay = true
            }
        case .char:
            c.mode = .tap
            if !spec.alternates.isEmpty && modifiers.isEmpty { c.timer = alternatesTimer(id) }
        default:
            c.mode = .special
        }
        contacts[id] = c
        view.needsDisplay = true
    }

    private func repeatTimer(_ id: Int, _ action: @escaping () -> Void) -> Timer {
        Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            let t = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { _ in action() }
            self?.contacts[id]?.timer = t
        }
    }

    private func isTap(_ m: KeyContact.Mode) -> Bool { if case .tap = m { return true }; return false }

    private func alternatesTimer(_ id: Int) -> Timer {
        Timer.scheduledTimer(withTimeInterval: 0.42, repeats: false) { [weak self] _ in
            guard let self, var c = self.contacts[id], case .tap = c.mode else { return }
            c.mode = .alternates
            c.altIndex = 0
            self.contacts[id] = c
            self.view?.needsDisplay = true
        }
    }

    func contactMoved(_ id: Int, to global: CGPoint) {
        guard visible, var c = contacts[id], let view, let panel else { return }
        if let k = c.key, k >= view.keys.count { return }
        let dx = global.x - c.startGlobal.x, dy = global.y - c.startGlobal.y
        switch c.mode {
        case .move:
            // Global coordinates point down, the window's up.
            panel.setFrameOrigin(NSPoint(x: c.startOrigin.x + dx, y: c.startOrigin.y - dy))
            return
        case .resize:
            let width = view.bounds.width / c.startScale
            liveScale = min(max(c.startScale * (1 + dx / max(width, 100)), 0.6), 1.5)
            layoutPanel(keepTopLeft: c.startOrigin)
            return
        default: break
        }
        let p = toLocal(global)
        c.current = p
        let unit = view.unit
        switch c.mode {
        case .tap:
            c.path.append(p); c.times.append(CACurrentMediaTime())
            let moved = hypot(p.x - c.start.x, p.y - c.start.y)
            if cfgKB.keyboardGlide && page == .letters && modifiers.isEmpty && moved > unit * 0.75,
               let k0 = c.key, view.keys[k0].spec.isLetterKey, view.keyIndex(at: p) != k0 {
                c.mode = .glide
                c.timer?.invalidate(); c.timer = nil
            } else if let k = view.keyIndex(at: p), k != c.key {
                c.key = k
                c.timer?.invalidate(); c.timer = nil
                if !view.keys[k].spec.alternates.isEmpty && modifiers.isEmpty { c.timer = alternatesTimer(id) }
            }
        case .glide:
            c.path.append(p); c.times.append(CACurrentMediaTime())
        case .alternates:
            if let k = c.key { c.altIndex = view.alternateIndex(for: k, at: p, count: alternates(for: view.keys[k].spec).count) }
        case .spaceHold:
            if abs(p.x - c.start.x) > unit * 0.6 {
                c.timer?.invalidate(); c.timer = nil
                c.mode = .spaceCursor; c.cursorRest = p
            }
        case .spaceCursor:
            let stepX = unit * 0.32, stepY = view.rowHeight * 0.55
            while p.x - c.cursorRest.x > stepX { sendKeyCode(124); c.cursorRest.x += stepX }
            while c.cursorRest.x - p.x > stepX { sendKeyCode(123); c.cursorRest.x -= stepX }
            while p.y - c.cursorRest.y > stepY { sendKeyCode(125); c.cursorRest.y += stepY }
            while c.cursorRest.y - p.y > stepY { sendKeyCode(126); c.cursorRest.y -= stepY }
            contextKnown = false
        default: break
        }
        contacts[id] = c
        view.needsDisplay = true
    }

    func contactEnded(_ id: Int) {
        guard let c = contacts.removeValue(forKey: id), let view else { return }
        c.timer?.invalidate()
        guard visible else { return }
        if let k = c.key, k >= view.keys.count { return }
        switch c.mode {
        case .tap:
            commitTap(c)
        case .glide:
            view.fadeTrail(c.path)
            finishGlide(c.path)
        case .alternates:
            if let k = c.key {
                let alts = alternates(for: view.keys[k].spec)
                if c.altIndex < alts.count { typeText(applyShift(alts[c.altIndex])); afterCharacter() }
            }
        case .spaceHold:
            typeSpace()
        case .special:
            if let k = c.key, view.keyIndex(at: c.current) == k { pressSpecial(view.keys[k].spec) }
        case .suggestion(let slot):
            if view.suggestionSlot(at: c.current) == slot { pickSuggestion(slot) }
        case .shortcut(let slot):
            if showsShortcuts && view.shortcutSlot(at: c.current) == slot { pressShortcut(slot) }
        case .move:
            // Dropped near the bottom edge: dock it there again.
            if let panel, panel.frame.minY - builtInScreen().frame.minY < 60 {
                var cfg = settingsModel.c
                cfg.keyboardX = -1; cfg.keyboardY = -1
                placeAtTop = false
                settingsModel.c = cfg
                layoutPanel(); publishFrame()
            } else {
                saveFloatingOrigin()
            }
        case .resize:
            // One config write: each write lays the panel out again from the stored values.
            var cfg = settingsModel.c
            if let s = liveScale { liveScale = nil; cfg.keyboardSize = s }
            if floating { (cfg.keyboardX, cfg.keyboardY) = floatingOrigin() }
            settingsModel.c = cfg
            layoutPanel(); publishFrame()
        case .strip(let control):
            guard view.stripControl(at: c.current) == control else { break }
            switch control {
            case .advanced:
                settingsModel.c.keyboardAdvanced.toggle()
                page = .letters
                clearModifiers(includingLocked: true)
                layoutPanel(); publishFrame()
            case .dock:
                settingsModel.c.keyboardX = -1; settingsModel.c.keyboardY = -1
                layoutPanel(); publishFrame()
            default: break
            }
        default: break
        }
        view.needsDisplay = true
    }

    /// Where the panel is now, relative to the built-in screen.
    private func floatingOrigin() -> (Double, Double) {
        guard let panel else { return (0, 0) }
        let screen = builtInScreen()
        return (max(panel.frame.minX - screen.frame.minX, 0), max(panel.frame.minY - screen.frame.minY, 0))
    }

    private func saveFloatingOrigin() {
        // Read both before writing: setting keyboardX alone would lay the panel out
        // with the old keyboardY (the bottom) and then save that.
        var cfg = settingsModel.c
        (cfg.keyboardX, cfg.keyboardY) = floatingOrigin()
        settingsModel.c = cfg
        layoutPanel(); publishFrame()
    }

    /// Contacts the view draws: the key each one is on and what it is doing.
    var activeContacts: [KeyContact] { Array(contacts.values) }

    // MARK: Typing

    func alternates(for spec: KeySpec) -> [String] {
        guard let t = spec.text else { return [] }
        return [t] + spec.alternates
    }

    /// Shift pressed by hand (not auto-capitals), which switches number keys to their symbols.
    var symbolShift: Bool { shift != .off && !(shiftIsAuto && shift == .once) }

    /// The text a key types now, with shift applied.
    func output(for spec: KeySpec) -> String? {
        guard let t = spec.text else { return nil }
        if shift != .off, let s = spec.shifted, !(shiftIsAuto && shift == .once) { return s }
        return applyShift(t)
    }

    func applyShift(_ s: String) -> String {
        guard shift != .off, s.count == 1 else { return s }
        return s.uppercased()
    }

    func label(for spec: KeySpec) -> String {
        if let l = spec.label { return l }
        guard let t = spec.text else { return "" }
        if spec.shifted != nil { return t }       // the shift symbol is drawn small above
        return applyShift(t)
    }

    func modifierFlags(includeShift: Bool) -> CGEventFlags {
        var f: CGEventFlags = []
        if modifiers.contains(.control) { f.insert(.maskControl) }
        if modifiers.contains(.option) { f.insert(.maskAlternate) }
        if modifiers.contains(.command) { f.insert(.maskCommand) }
        if includeShift && shift != .off && !shiftIsAuto { f.insert(.maskShift) }
        return f
    }

    /// One-shot modifiers end after the next key; double-tapped ones stay on.
    private func clearModifiers(includingLocked: Bool = false) {
        if includingLocked { lockedModifiers.removeAll() }
        modifiers = lockedModifiers
    }

    /// Lets go of every held modifier, before Touchintosh quits.
    func releaseModifiers() {
        clearModifiers(includingLocked: true)
        shift = .off
        holdModifiers()          // now: the process is about to exit
    }

    /// A pen, finger or mouse click outside the keyboard ended: one-shot modifiers are used up.
    func clickEnded() {
        let shiftOnce = shift == .once && !shiftIsAuto
        guard modifiers != lockedModifiers || shiftOnce else { return }
        clearModifiers()
        if shiftOnce { shift = .off }
        view?.needsDisplay = true
    }

    /// Several state changes in a row (shift and shiftIsAuto together) settle into one sync.
    private func scheduleHold() {
        guard !holdScheduled else { return }
        holdScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.holdScheduled = false
            self?.holdModifiers()
        }
    }

    /// Presses or releases the real ⌘ ⇧ ⌥ ⌃ keys to match the lit modifiers, so apps that
    /// watch the modifier state (Photoshop's ⌥-click, ⌘-drag, ⇧-click) see them held.
    /// Auto-capitals never hold Shift; only a hand-pressed shift does.
    private func holdModifiers() {
        let keys: [(CGEventFlags, CGKeyCode)] = [(.maskCommand, 55), (.maskShift, 56), (.maskAlternate, 58), (.maskControl, 59)]
        let want = modifierFlags(includeShift: true)
        func post(_ key: CGKeyCode, down: Bool) {
            guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { return }
            ev.type = .flagsChanged
            ev.flags = heldNow
            ev.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            ev.post(tap: .cghidEventTap)
        }
        for (f, key) in keys where heldNow.contains(f) && !want.contains(f) { heldNow.remove(f); post(key, down: false) }
        for (f, key) in keys where want.contains(f) && !heldNow.contains(f) { heldNow.insert(f); post(key, down: true) }
        keyboardShared.heldFlags = heldNow
    }

    private func commitTap(_ c: KeyContact) {
        guard let view, let k = c.key, k < view.keys.count else { return }
        let spec = view.keys[k].spec
        // With Control, Option or Command, send the key itself so the shortcut works.
        if !modifiers.isEmpty, let code = spec.code ?? spec.text.flatMap({ usKeyCodes[$0.lowercased()] }) {
            sendKeyCode(code, flags: modifierFlags(includeShift: true))
            clearModifiers()
            contextKnown = false; context = ""; lastGlide = nil
            if shift == .once { shift = .off }
            view.rebuild()
            return
        }
        guard let t = output(for: spec) else { return }
        let punctuation = ".,?!:;)،؟؛"
        if smartSpace && t.count == 1 && punctuation.contains(t) && context.hasSuffix(" ") {
            // "word" + smart space + "." -> "word. "
            postBackspace(1)
            typeText(t)
            typeText(" ")
            smartSpace = true
        } else {
            typeText(t)
            smartSpace = false
        }
        lastGlide = nil
        if page != .letters && t == "'" { page = .letters; forgetKeys(); view.rebuild() }
        afterCharacter()
    }

    private func afterCharacter() {
        if shift == .once { shift = .off; shiftIsAuto = false }
        refreshShiftAuto()
        updateSuggestions()
        view?.rebuild()
    }

    private func typeSpace() {
        let now = CACurrentMediaTime()
        if now - lastSpaceTime < 0.6, context.hasSuffix(" "), !smartSpace,
           let before = context.dropLast().last, before.isLetter || before.isNumber {
            postBackspace(1)
            typeText(". ")
            lastSpaceTime = 0
        } else if smartSpace && context.hasSuffix(" ") {
            smartSpace = false         // the space is already there
            lastSpaceTime = now
        } else {
            if language == .en && currentWord() == "i" { postBackspace(1); typeText("I") }
            learnCurrentWord()
            typeText(" ")
            lastSpaceTime = now
        }
        smartSpace = false
        lastGlide = nil
        if page != .letters { page = .letters; forgetKeys() }
        afterCharacter()
    }

    /// Keys are indexes into the current page, so a page change ends what other fingers were doing.
    private func forgetKeys() {
        for (id, var c) in contacts { c.timer?.invalidate(); c.timer = nil; c.key = nil; c.mode = .consumed; contacts[id] = c }
    }

    private func pressSpecial(_ spec: KeySpec) {
        switch spec.kind {
        case .ret:
            learnCurrentWord()
            sendKeyCode(36, flags: modifierFlags(includeShift: true))
            clearModifiers()
            context.append("\n"); smartSpace = false; lastGlide = nil
            afterCharacter()
        case .tab:
            sendKeyCode(48, flags: modifierFlags(includeShift: true))
            clearModifiers(); contextKnown = false; context = ""
            afterCharacter()
        case .esc:
            sendKeyCode(53, flags: modifierFlags(includeShift: true))
            clearModifiers()
            view?.rebuild()
        case .space:   // only reached with a modifier held, e.g. ⌘Space
            sendKeyCode(49, flags: modifierFlags(includeShift: true))
            clearModifiers(); contextKnown = false
            view?.rebuild()
        case .globe:
            language = language == .en ? .ar : .en
            page = .letters
            forgetKeys()
            loadLexicon(language)
            refreshShiftAuto()
            updateSuggestions()
            layoutPanel(); publishFrame()
        case .hide:
            hide(byUser: true)
        case .page(let p):
            page = p
            forgetKeys()
            view?.rebuild()
        default: break
        }
    }

    /// A shortcut bar tap: -1 switches the group, anything else sends that shortcut.
    /// Move shortcuts keep a hand-pressed shift, so they extend the selection.
    private func pressShortcut(_ slot: Int) {
        if slot < 0 {
            let all = ShortcutGroup.allCases
            shortcutGroup = all[(shortcutGroup.rawValue + 1) % all.count]
            view?.needsDisplay = true
            return
        }
        let list = shortcuts(shortcutGroup)
        guard slot < list.count else { return }
        var flags = list[slot].flags
        if shortcutGroup == .move && shift != .off && !shiftIsAuto { flags.insert(.maskShift) }
        sendShortcut(list[slot].code, flags: flags)
        clearModifiers()
        contextKnown = false; context = ""; lastGlide = nil; smartSpace = false
        view?.rebuild()
    }

    /// Presses the modifier keys around the key, as a hardware keyboard does. ⌘Tab and
    /// Spotlight only react to real modifier presses, not to flags on the key alone.
    private func sendShortcut(_ code: CGKeyCode, flags: CGEventFlags) {
        let mods: [(CGEventFlags, CGKeyCode)] = [(.maskCommand, 55), (.maskShift, 56), (.maskAlternate, 58), (.maskControl, 59)]
            .filter { flags.contains($0.0) }
        func post(_ key: CGKeyCode, down: Bool, _ f: CGEventFlags) {
            guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { return }
            ev.flags = f
            ev.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            ev.post(tap: .cghidEventTap)
        }
        var held: CGEventFlags = []
        for (f, key) in mods { held.insert(f); post(key, down: true, held) }
        post(code, down: true, flags)
        post(code, down: false, flags)
        for (f, key) in mods.reversed() { held.remove(f); post(key, down: false, held) }
    }

    private func deleteBackward() {
        if !modifiers.isEmpty {
            sendKeyCode(51, flags: modifierFlags(includeShift: true))
            clearModifiers(); contextKnown = false; context = ""
            view?.rebuild()
            return
        }
        if let g = lastGlide, context.hasSuffix(g.typed) {
            // Like iOS: backspace right after a glided word removes the whole word.
            postBackspace(g.typed.count)
            lastGlide = nil
        } else {
            postBackspace(1)
        }
        smartSpace = false
        afterCharacter()
    }

    private func deleteWordBackward() {
        sendKeyCode(51, flags: .maskAlternate)
        contextKnown = false; context = ""
        afterCharacter()
    }

    private func finishGlide(_ path: [CGPoint]) {
        guard let view, let lex = lexicons[language] else { return }
        let unit = view.unit
        let centers = view.letterCenters().mapValues { CGPoint(x: $0.x / unit, y: $0.y / unit) }
        let scaled = path.map { CGPoint(x: $0.x / unit, y: $0.y / unit) }
        let found = GlideDecoder.decode(path: scaled, keyCenters: centers, lexicon: lex, limit: 4)
        guard let best = found.first else { return }
        ensureContext()
        var word = best.word
        if shift != .off || shouldAutoCapitalize() { word = capitalized(word) }
        if shift == .locked { word = word.uppercased() }
        var typed = ""
        if let last = context.last, !last.isWhitespace, !"([{\"'“‘".contains(last) { typed += " " }
        typed += word + " "
        typeText(typed)
        smartSpace = true
        lastGlide = (word, typed, found.dropFirst().map { $0.word })
        if shift == .once { shift = .off; shiftIsAuto = false }
        refreshShiftAuto()
        let alts = Array(found.dropFirst().map(\.word).prefix(2))
        suggestions = [alts.count > 0 ? alts[0] : "", word, alts.count > 1 ? alts[1] : ""]
        view.rebuild()
    }

    private func capitalized(_ w: String) -> String {
        guard language == .en, let f = w.first else { return w }
        return f.uppercased() + w.dropFirst()
    }

    private func pickSuggestion(_ slot: Int) {
        let choice = suggestions[slot]
        guard !choice.isEmpty else { return }
        if let g = lastGlide, context.hasSuffix(g.typed) {
            // Swap the glided word for the one picked.
            guard choice != g.word else { return }
            postBackspace(g.typed.count)
            let lead = g.typed.hasPrefix(" ") ? " " : ""
            let replacement = lead + choice + " "
            typeText(replacement)
            lexicons[language]?.learn(choice)
            lastGlide = (choice, replacement, [g.word] + g.alternatives.filter { $0 != choice })
            suggestions = [g.word, choice, g.alternatives.first { $0 != choice && $0 != g.word } ?? ""]
            smartSpace = true
        } else {
            let current = currentWord()
            let literal = choice.hasPrefix("\"") && choice.hasSuffix("\"") && choice.count >= 2
            let word = literal ? String(choice.dropFirst().dropLast()) : choice
            postBackspace(current.count)
            typeText(word + " ")
            lexicons[language]?.learn(word)
            smartSpace = true
            suggestions = ["", "", ""]
        }
        refreshShiftAuto()
        view?.rebuild()
    }

    private func learnCurrentWord() {
        let w = currentWord()
        if w.count >= 2, NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0, language: language.rawValue, wrap: false,
                                                             inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound {
            lexicons[language]?.learn(w)
        }
    }

    private func currentWord() -> String {
        String(context.reversed().prefix { $0.isLetter || $0 == "'" }.reversed())
    }

    private func updateSuggestions() {
        let w = currentWord()
        guard !w.isEmpty, contextKnown || !context.isEmpty else { suggestions = ["", "", ""]; return }
        let ns = w as NSString
        let found = NSSpellChecker.shared.completions(forPartialWordRange: NSRange(location: 0, length: ns.length), in: w,
                                                      language: language.rawValue, inSpellDocumentWithTag: 0) ?? []
        let others = found.filter { $0 != w }
        suggestions = ["\"\(w)\"", others.first ?? "", others.dropFirst().first ?? ""]
    }

    // MARK: Context and capitals

    /// Called by the router when the user clicks or taps outside the keyboard.
    func focusMayHaveChanged() {
        contextKnown = false
        context = ""
        smartSpace = false
        lastGlide = nil
        suggestions = ["", "", ""]
        guard visible else { return }
        refreshShiftAuto()
        view?.rebuild()
    }

    private func ensureContext() {
        guard !contextKnown else { return }
        context = focusedTextBeforeCaret() ?? ""
        contextKnown = true
    }

    private func shouldAutoCapitalize() -> Bool {
        guard cfgKB.keyboardAutoCap, language == .en, !advanced else { return false }
        ensureContext()
        let trimmed = context.replacingOccurrences(of: " ", with: "")
        if trimmed.isEmpty { return true }
        if context.hasSuffix("\n") { return true }
        guard context.hasSuffix(" "), let last = trimmed.last else { return false }
        return ".!?".contains(last)
    }

    private func refreshShiftAuto() {
        guard shift != .locked else { return }
        if page == .letters && shouldAutoCapitalize() {
            if shift == .off { shift = .once; shiftIsAuto = true }
        } else if shift == .once && shiftIsAuto {
            shift = .off; shiftIsAuto = false
        }
    }

    // MARK: Output

    private func typeText(_ s: String) {
        ensureContextForAppend()
        let utf16 = Array(s.utf16)
        var i = 0
        while i < utf16.count {
            let chunk = Array(utf16[i..<min(i + 16, utf16.count)])
            for down in [true, false] {
                guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                ev.flags = []
                chunk.withUnsafeBufferPointer { ev.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                ev.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
                ev.post(tap: .cghidEventTap)
            }
            i += 16
        }
        context.append(s)
        if context.count > 200 { context = String(context.suffix(120)) }
    }

    private func ensureContextForAppend() {
        if !contextKnown { context = focusedTextBeforeCaret() ?? ""; contextKnown = true }
    }

    private func postBackspace(_ n: Int) {
        for _ in 0..<max(n, 0) { sendKeyCode(51) }
        if context.count >= n { context.removeLast(n) } else { context = ""; contextKnown = false }
    }

    private func sendKeyCode(_ code: CGKeyCode, flags: CGEventFlags = []) {
        for down in [true, false] {
            guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
            ev.flags = flags
            ev.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            ev.post(tap: .cghidEventTap)
        }
    }

    // MARK: Debug hooks (kbctl)

    /// Renders the keyboard (on a grey stand-in for the glass) to a PNG.
    func snapshot(to path: String) {
        guard let view, let glass else { return }
        let r = view.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(r.width), pixelsHigh: Int(r.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSColor(white: dark ? 0.35 : 0.97, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: r.width, height: r.height).fill()
        NSColor(white: dark ? 0.16 : 0.80, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: glass.frame.width, height: glass.frame.height),
                     xRadius: glassCorner, yRadius: glassCorner).fill()
        let cg = ctx.cgContext
        cg.translateBy(x: 0, y: r.height); cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.draw(r) }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Simulates a held touch path in keyboard-view coordinates (id 99).
    func simulate(_ points: [CGPoint], hold: Bool) {
        guard let panel, let view else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        func global(_ p: CGPoint) -> CGPoint {
            let s = panel.convertPoint(toScreen: view.convert(p, to: nil))
            return CGPoint(x: s.x, y: primaryHeight - s.y)
        }
        contactBegan(99, at: global(points[0]))
        for p in points.dropFirst() { contactMoved(99, to: global(p)) }
        if !hold { contactEnded(99) }
    }

    /// Forgets a contact without typing anything.
    func cancelContact(_ id: Int) {
        contacts.removeValue(forKey: id)?.timer?.invalidate()
        view?.needsDisplay = true
    }
}

// MARK: - Accessibility helpers

private let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
private var chromiumEnabled = Set<pid_t>()
private let chromiumLock = NSLock()

func focusedElement() -> AXUIElement? {
    enableChromiumAccessibility()
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.08)
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
    let el = f as! AXUIElement
    AXUIElementSetMessagingTimeout(el, 0.08)
    return el
}

/// Chromium-based apps only build their accessibility tree when asked to.
func enableChromiumAccessibility(pid: pid_t? = nil, bundleID: String? = nil) {
    let app = NSWorkspace.shared.frontmostApplication
    guard let pid = pid ?? app?.processIdentifier, let id = bundleID ?? app?.bundleIdentifier,
          ["com.brave.Browser", "com.google.Chrome", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "company.thebrowser.Browser"]
            .contains(where: { id.hasPrefix($0) }) else { return }
    chromiumLock.lock()
    let fresh = chromiumEnabled.insert(pid).inserted
    chromiumLock.unlock()
    guard fresh else { return }
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
}

func isEditable(_ el: AXUIElement) -> Bool {
    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
    if let r = role as? String, editableRoles.contains(r) { return true }
    var settable: DarwinBoolean = false
    if AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value)
        return value is String
    }
    return false
}

func focusedIsEditable() -> Bool { focusedElement().map(isEditable) ?? false }

/// Up to 80 characters before the caret in the focused text field, if the app tells us.
func focusedTextBeforeCaret() -> String? {
    guard let el = focusedElement() else { return nil }
    var value: CFTypeRef?, range: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value) == .success,
          let text = value as? String else { return nil }
    var caret = (text as NSString).length
    if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
       let r = range, CFGetTypeID(r) == AXValueGetTypeID() {
        var cf = CFRange()
        if AXValueGetValue(r as! AXValue, .cfRange, &cf) { caret = min(max(cf.location, 0), caret) }
    }
    let before = (text as NSString).substring(to: caret)
    return String(before.suffix(80))
}

/// True when the focused text field sits in the bottom part of the built-in screen,
/// where the docked keyboard would cover it.
func focusedFieldIsLow() -> Bool {
    guard let el = focusedElement() else { return false }
    var pos: CFTypeRef?, size: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pos) == .success,
          AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &size) == .success,
          let p = pos, let s = size, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return false }
    var origin = CGPoint.zero, extent = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &origin)
    AXValueGetValue(s as! AXValue, .cgSize, &extent)
    let display = builtInDisplay().bounds
    // A field taller than half the screen (a document) can scroll; only small fields move it.
    guard extent.height < display.height * 0.5 else { return false }
    return origin.y + min(extent.height, 60) > display.maxY - display.height * 0.42
}

// MARK: - Focus watcher

/// Follows keyboard focus in the app in front, for "show whenever a text field is active".
final class FocusWatcher {
    static let shared = FocusWatcher()
    private var observer: AXObserver?
    private var watchedPID: pid_t = 0

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.watch(app)
            KeyboardController.shared.scheduleFocusCheck(fromTouch: false)
        }
        watch(NSWorkspace.shared.frontmostApplication)
    }

    private func watch(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != watchedPID, app.processIdentifier != getpid() else { return }
        if let old = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .defaultMode)
        }
        observer = nil
        watchedPID = app.processIdentifier
        enableChromiumAccessibility(pid: app.processIdentifier, bundleID: app.bundleIdentifier)
        var obs: AXObserver?
        guard AXObserverCreate(app.processIdentifier, { _, _, _, _ in
            KeyboardController.shared.scheduleFocusCheck(fromTouch: false)
        }, &obs) == .success, let obs else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXObserverAddNotification(obs, element, kAXFocusedUIElementChangedNotification as CFString, nil)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
    }
}
