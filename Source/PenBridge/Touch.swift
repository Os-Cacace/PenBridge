// Touch: multi-finger gestures for the Wacom touchscreen (report 12, 5 finger
// slots per report, hybrid mode up to 10 contacts). One-finger taps stay with
// VoodooI2C; this adds one- and two-finger scroll with momentum, pinch, rotate,
// two-finger tap and three- and four-finger swipes. All of it is set from Config.
//
// Pinch and rotate send trackpad-style gesture events wrapped in begin/end events.
// A begin without an end can leave WindowServer stuck mid-gesture (blocking clicks),
// so every exit path ends the gesture.
//
// Report 12 is decoded from its raw bytes (layout from the HID report descriptor):
// [0] report ID, [1] unused, [2] contact count, then 5 slots of 7 bytes from offset 3:
// +0 bit0 tip / bit2 confidence, +1..2 contact ID, +3..4 X, +5..6 Y.
// Reading element values with IOHIDDeviceGetValue instead blocks on VoodooI2C.
import Foundation
import IOKit.hid
import CoreGraphics

let touchReportID: UInt32 = 12
let touchMaxX = 12372.0, touchMaxY = 6960.0
let touchSlots = 5, touchSlotBase = 3, touchSlotStride = 7, touchCountOffset = 2

struct Contact { var id: Int; var x: Double; var y: Double }

enum GestureMode: String { case none, undecided, scroll, pinch, rotate, swipe }

// Scroll events and momentum, shared by every way of scrolling.
final class Scroller {
    private var location = CGPoint.zero
    private var restX = 0.0, restY = 0.0
    private var velocity = CGVector.zero   // points per 1/60 s
    private var lastMove = Date.distantPast
    private var momentumTimer: Timer?
    private var momentumStarted = false

    func begin(at p: CGPoint) {
        stopMomentum()
        location = p; restX = 0; restY = 0; velocity = .zero; lastMove = Date()
        post(dx: 0, dy: 0, phase: 1)
    }

    func move(dx rawX: Double, dy rawY: Double, speed: Double) {
        let k = speed * (cfg.reverseScroll ? -1 : 1)
        let dx = rawX * k, dy = rawY * k
        let now = Date(), dt = now.timeIntervalSince(lastMove)
        if dt > 0.001 {
            let blend = min(dt * 60, 1)   // smooth toward the per-frame speed
            velocity = CGVector(dx: velocity.dx + blend * (dx / (dt * 60) - velocity.dx),
                                dy: velocity.dy + blend * (dy / (dt * 60) - velocity.dy))
        }
        lastMove = now
        post(dx: dx, dy: dy, phase: 2)
    }

    func end() {
        post(dx: 0, dy: 0, phase: 4)
        if cfg.momentum && Date().timeIntervalSince(lastMove) < 0.08 { startMomentum() }
    }

    func cancel() { post(dx: 0, dy: 0, phase: 4) }

    private func startMomentum() {
        stopMomentum()
        momentumStarted = false
        momentumTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.velocity.dx *= cfg.momentumGlide; self.velocity.dy *= cfg.momentumGlide
            if hypot(self.velocity.dx, self.velocity.dy) < 0.5 { self.stopMomentum(); return }
            self.post(dx: self.velocity.dx, dy: self.velocity.dy, phase: 0, momentum: self.momentumStarted ? 2 : 1)
            self.momentumStarted = true
        }
    }

    func stopMomentum() {
        guard let t = momentumTimer else { return }
        t.invalidate(); momentumTimer = nil
        if momentumStarted { post(dx: 0, dy: 0, phase: 0, momentum: 3) }
    }

    // phase: 1 began, 2 changed, 4 ended; momentum: 1 begin, 2 continue, 3 end
    private func post(dx: Double, dy: Double, phase: Int64, momentum: Int64 = 0) {
        // Whole-point deltas carry their remainder forward, so slow scrolls aren't lost to rounding.
        restX += dx; restY += dy
        let wholeX = restX.rounded(), wholeY = restY.rounded()
        restX -= wholeX; restY -= wholeY
        guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                               wheel1: Int32(wholeY), wheel2: Int32(wholeX), wheel3: 0) else { return }
        ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        ev.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        ev.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        ev.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: wholeY)
        ev.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: wholeX)
        ev.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
        ev.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
        ev.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        ev.location = location
        ev.post(tap: .cghidEventTap)
    }
}

let scroller = Scroller()

final class TouchGestures {
    // Hybrid-mode frame assembly.
    private var expected = 0
    private var frame: [Contact] = []

    private(set) var fingerCount = 0
    private var mode: GestureMode = .none
    private var startCentroid = CGPoint.zero, lastCentroid = CGPoint.zero
    private var startSpread = 0.0, lastSpread = 0.0
    private var startAngle = 0.0, lastAngle = 0.0
    private var maxFingers = 0
    private var gestureStart = Date.distantPast
    private var swipeFired = false
    private var zoomRef = 0.0
    private var smoothZoom = true
    private(set) var lastReport = Date.distantPast

    var onFingerCountChange: ((Int, Int) -> Void)?
    var onOneFinger: ((CGPoint) -> Void)?

    // True only while multi-finger touch data is actually arriving, so a stale
    // finger count can never keep blocking clicks.
    var multiFingerActive: Bool { fingerCount >= 2 && Date().timeIntervalSince(lastReport) < 0.15 }
    var oneFingerActive: Bool { fingerCount == 1 && Date().timeIntervalSince(lastReport) < 0.15 }
    var gestureName: String {
        switch mode {
        case .none: return fingerCount == 1 ? "One finger" : "None"
        case .undecided: return "\(maxFingers) fingers"
        case .scroll: return "Scroll"
        case .pinch: return "Pinch"
        case .rotate: return "Rotate"
        case .swipe: return "Swipe"
        }
    }

    // Call on the input thread, so the timer runs on its run loop.
    func startWatchdog() {
        // If reports stop without a final "lifted" frame, treat every
        // finger as lifted and end any gesture cleanly.
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.fingerCount > 0 || self.mode != .none,
                  Date().timeIntervalSince(self.lastReport) > 0.25 else { return }
            log("touch: watchdog reset (fingers=\(self.fingerCount))")
            self.reset()
        }
    }

    func reset() {
        expected = 0
        if fingerCount > 0 || mode != .none { finish([]) }
    }

    func handleReport(_ reportID: UInt32, _ report: UnsafePointer<UInt8>, _ length: Int) {
        let needed = touchSlotBase + touchSlots * touchSlotStride
        guard reportID == touchReportID, length >= needed, Int(report[0]) == Int(touchReportID) else { return }
        func u16(_ o: Int) -> Int { Int(report[o]) | Int(report[o + 1]) << 8 }
        lastReport = Date()
        touchReportCount &+= 1

        if cfg.paused || !cfg.touchEnabled { reset(); return }

        // Palm rejection: the pen wins while its reports are arriving and briefly afterwards.
        if cfg.palmRejection && lastReport.timeIntervalSince(pen.lastReport) < max(cfg.palmDelay, 0.03) {
            reset()
            return
        }

        let count = Int(report[touchCountOffset])
        if count > 0 { expected = count; frame.removeAll(keepingCapacity: true) }
        if expected == 0 { finish([]); return }
        for slot in 0..<touchSlots where frame.count < expected {
            let b = touchSlotBase + slot * touchSlotStride
            if report[b] & 0x01 != 0 {
                frame.append(Contact(id: u16(b + 1), x: Double(u16(b + 3)), y: Double(u16(b + 5))))
            } else {
                expected -= 1   // a lifted contact still occupies a slot
            }
        }
        if frame.count >= expected { finish(frame); expected = 0 }
    }

    // MARK: Gesture recognition

    private func screenPoint(_ c: Contact) -> CGPoint {
        panelPoint(nx: c.x / touchMaxX, ny: c.y / touchMaxY)
    }

    private func finish(_ contacts: [Contact]) {
        let n = contacts.count
        if n != fingerCount { onFingerCountChange?(fingerCount, n) }
        let previous = fingerCount
        fingerCount = n

        if n == 1 { onOneFinger?(screenPoint(contacts[0])) }
        if n < 2 {
            if mode != .none {
                if isTwoFingerTap { postRightClick(at: startCentroid) }
                endGesture()
            }
            if n == 0 { maxFingers = 0 }
            if previous != n { log("touch: fingers \(previous) -> \(n)") }
            return
        }
        let pts = contacts.map(screenPoint)
        let centroid = CGPoint(x: pts.map(\.x).reduce(0, +) / Double(n), y: pts.map(\.y).reduce(0, +) / Double(n))
        let spread = pts.map { hypot($0.x - centroid.x, $0.y - centroid.y) }.reduce(0, +) / Double(n)
        let angle = atan2(pts[1].y - pts[0].y, pts[1].x - pts[0].x) * 180 / .pi

        if mode == .none || n != maxFingers && n > maxFingers {
            if mode != .none { endGesture() }
            maxFingers = n
            mode = .undecided
            gestureStart = Date()
            startCentroid = centroid; lastCentroid = centroid
            startSpread = spread; lastSpread = spread
            startAngle = angle; lastAngle = angle
            swipeFired = false
            return
        }

        let move = hypot(centroid.x - startCentroid.x, centroid.y - startCentroid.y)
        let spreadChange = abs(spread - startSpread)
        let turned = abs(angleDelta(angle, startAngle))

        if mode == .undecided {
            if maxFingers >= 3 {
                if cfg.swipeEnabled && move > cfg.swipeStart * 0.45 { mode = .swipe }
            } else if cfg.pinchEnabled && spreadChange > cfg.pinchStart && spreadChange > move * 0.8 {
                mode = .pinch; zoomRef = max(startSpread, 20)
                smoothZoom = cfg.smoothZoom
                if smoothZoom { postGesture(beginEnd: 61); postMagnify(phase: 1, amount: 0) }
            } else if cfg.rotateEnabled && turned > cfg.rotateStart && move < 30 {
                mode = .rotate
                postGesture(beginEnd: 61); postRotate(phase: 1, degrees: 0)
            } else if cfg.twoFingerScroll && move > cfg.twoFingerStart {
                mode = .scroll; scroller.begin(at: centroid)
            }
            if mode == .undecided { return }
            log("touch: \(maxFingers)-finger \(mode.rawValue)")
        }

        switch mode {
        case .scroll:
            scroller.move(dx: centroid.x - lastCentroid.x, dy: centroid.y - lastCentroid.y, speed: cfg.scrollSpeed)
        case .pinch:
            if smoothZoom {
                postMagnify(phase: 2, amount: (spread - lastSpread) / max(startSpread, 40) * cfg.zoomSpeed)
            } else if spread > zoomRef * 1.25 {   // one step per 25% change in finger spread
                postZoom(in: true); zoomRef = spread
            } else if spread < zoomRef / 1.25 {
                postZoom(in: false); zoomRef = spread
            }
        case .rotate:
            let step = angleDelta(angle, lastAngle)
            if abs(step) < 45 { postRotate(phase: 2, degrees: -step) }   // a bigger jump means the contacts swapped order
        case .swipe:
            if !swipeFired && move > cfg.swipeStart {
                swipeFired = true
                let action = cfg.swipeAction(fingers: maxFingers, dx: centroid.x - startCentroid.x, dy: centroid.y - startCentroid.y)
                perform(action)
            }
        default: break
        }
        lastCentroid = centroid; lastSpread = spread; lastAngle = angle
    }

    private var isTwoFingerTap: Bool {
        cfg.twoFingerTap && mode == .undecided && maxFingers == 2 && Date().timeIntervalSince(gestureStart) < 0.3
    }

    private func angleDelta(_ a: Double, _ b: Double) -> Double {
        var d = a - b
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        return d
    }

    private func endGesture() {
        if mode == .scroll { scroller.end() }
        if mode == .pinch && smoothZoom { postMagnify(phase: 4, amount: 0); postGesture(beginEnd: 62) }
        if mode == .rotate { postRotate(phase: 4, degrees: 0); postGesture(beginEnd: 62) }
        if mode != .undecided { log("touch: \(mode.rawValue) ended") }
        mode = .none
    }

    // MARK: Event synthesis

    // Private gesture events (type 29, NSEventTypeGesture). Field 110 is the gesture
    // subtype: 61 begin gesture, 62 end gesture, 8 magnify, 5 rotate; 113 magnification,
    // 114 rotation in degrees, 132 phase.
    private func postGesture(beginEnd subtype: Int64) {
        guard let ev = CGEvent(source: nil), let gestureType = CGEventType(rawValue: 29) else { return }
        ev.type = gestureType
        ev.location = lastCentroid
        ev.setIntegerValueField(CGEventField(rawValue: 110)!, value: subtype)
        ev.post(tap: .cghidEventTap)
    }

    private func postMagnify(phase: Int64, amount: Double) {
        guard let ev = CGEvent(source: nil), let gestureType = CGEventType(rawValue: 29) else { return }
        ev.type = gestureType
        ev.location = lastCentroid
        ev.setIntegerValueField(CGEventField(rawValue: 110)!, value: 8)
        ev.setDoubleValueField(CGEventField(rawValue: 113)!, value: amount)
        ev.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
        ev.post(tap: .cghidEventTap)
    }

    private func postRotate(phase: Int64, degrees: Double) {
        guard let ev = CGEvent(source: nil), let gestureType = CGEventType(rawValue: 29) else { return }
        ev.type = gestureType
        ev.location = lastCentroid
        ev.setIntegerValueField(CGEventField(rawValue: 110)!, value: 5)
        ev.setDoubleValueField(CGEventField(rawValue: 114)!, value: degrees)
        ev.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
        ev.post(tap: .cghidEventTap)
    }

    private func postRightClick(at p: CGPoint) {
        log("touch: two-finger tap")
        for type in [CGEventType.rightMouseDown, .rightMouseUp] {
            guard let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .right) else { continue }
            ev.setIntegerValueField(.mouseEventClickState, value: 1)
            ev.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            ev.post(tap: .cghidEventTap)
        }
    }

    // ⌘= zooms in, ⌘- zooms out (key codes 24 and 27).
    private func postZoom(in zoomIn: Bool) {
        postKey(zoomIn ? 24 : 27, flags: .maskCommand)
    }

    private func perform(_ action: SwipeAction) {
        // Mission Control only takes ⌃-arrows that carry the fn and keypad flags a real arrow key has.
        let arrow: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
        log("touch: swipe action \(action.rawValue)")
        switch action {
        case .none: break
        case .nextSpace: postKey(124, flags: arrow)
        case .previousSpace: postKey(123, flags: arrow)
        case .missionControl: postKey(126, flags: arrow)
        case .appExpose: postKey(125, flags: arrow)
        case .showDesktop: postKey(103, flags: .maskSecondaryFn)   // F11
        case .back: postKey(33, flags: .maskCommand)
        case .forward: postKey(30, flags: .maskCommand)
        }
    }

    private func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = .maskControl) {
        for down in [true, false] {
            guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else { continue }
            ev.flags = flags
            ev.post(tap: .cghidEventTap)
        }
    }
}

// MARK: One-finger scroll and drag
//
// A one-finger swipe scrolls, like a phone or the touch MacBook Pro, and a tap
// still clicks. VoodooI2C turns a finger held still for ~0.5 s into a right-click
// and sends nothing more until the lift, so that long-press is caught here: move
// after it to drag (select text, move windows), lift without moving to right-click.
// The drag is driven from the touch reports themselves.
//
// The pen scrolls the same way while its upper side button is held: that button
// puts the pen in eraser mode (invert bit hovering, eraser bit touching), so
// eraser strokes become scrolls.
final class OneFingerScroll {
    enum State { case idle, pending, scrolling, armed, dragging, liftClick }
    private(set) var state = State.idle
    private var downEvent: CGEvent?
    private var start = CGPoint.zero, last = CGPoint.zero
    private var scrollSpeed = 1.0
    private var liftTimer: Timer?
    private var touchRef: CGPoint?
    private var lastTap = Date.distantPast, lastTapAt = CGPoint.zero, tapCount = 0

    // Returns the event to pass on, or nil to swallow it.
    func handle(_ type: CGEventType, _ ev: CGEvent) -> CGEvent? {
        let loc = ev.location
        switch (type, state) {
        case (.leftMouseDown, .idle), (.leftMouseDown, .pending), (.leftMouseDown, .scrolling):
            scroller.stopMomentum()
            state = .pending; downEvent = ev.copy()
            start = loc; last = loc
            return nil
        case (.leftMouseDragged, .pending):
            if hypot(loc.x - start.x, loc.y - start.y) < cfg.oneFingerStart { return nil }
            scrollSpeed = cfg.scrollSpeed
            beginScroll()
            scroll(to: loc)
            return nil
        case (.leftMouseDragged, .scrolling):
            scroll(to: loc)
            return nil
        case (.leftMouseUp, .pending):
            // A tap: replay the held-back down, then this up, in order. Taps close in
            // time and place count up (double-click), which macOS needs for a
            // double-tap on a title bar to fill the screen.
            state = .idle
            let now = Date()
            let again = now.timeIntervalSince(lastTap) < cfg.doubleTapTime && hypot(loc.x - lastTapAt.x, loc.y - lastTapAt.y) < 30
            tapCount = again ? tapCount + 1 : 1
            lastTap = now; lastTapAt = loc
            let up = ev.copy()
            for e in [downEvent, up] { e?.setIntegerValueField(.mouseEventClickState, value: Int64(tapCount)) }
            replay(downEvent); replay(up)
            return nil
        case (.leftMouseUp, .scrolling):
            // Mouse-ups always pass (a dropped one once froze all input); this one
            // has no down before it, so apps ignore it.
            endScroll()
            return ev
        case (.rightMouseDown, .idle):
            // VoodooI2C's long-press: wait to see whether the finger moves.
            scroller.stopMomentum()
            state = .armed; start = loc; last = loc; touchRef = nil
            return nil
        case (.rightMouseUp, _):
            return ev
        case (.rightMouseDown, _), (.mouseMoved, .armed), (.mouseMoved, .dragging),
             (.leftMouseDown, .liftClick), (.leftMouseDragged, .liftClick):
            return state == .idle ? ev : nil
        case (.leftMouseDown, .armed), (.leftMouseDown, .dragging):
            return nil
        case (.leftMouseUp, .armed), (.leftMouseUp, .dragging):
            // VoodooI2C's lift click beat the touch report's lift.
            touchLifted(); finishLift()
            return ev
        case (.leftMouseUp, .liftClick):
            // VoodooI2C's own click at the lift, already handled from the touch reports.
            finishLift()
            return ev
        default:
            return ev
        }
    }

    // The pen with its eraser-mode button held: every stroke scrolls, driven from
    // the pen reports (VoodooI2C sends no usable mouse events for eraser strokes).
    func penBegan(_ p: CGPoint) {
        scroller.stopMomentum()
        start = p; last = p
        scrollSpeed = cfg.penScrollSpeed
        log("touch: pen scroll")
        beginScroll()
    }

    func penMoved(_ p: CGPoint) {
        if state == .scrolling { scroll(to: p) }
    }

    func penEnded() {
        if state == .scrolling { endScroll() }
    }

    // Every one-finger touch frame, in screen coordinates.
    // Positions are measured from the first touch frame after the long-press and
    // applied to the cursor, since the report and cursor mappings differ slightly.
    func touchMoved(_ p: CGPoint) {
        guard state == .armed || state == .dragging else { return }
        guard let ref = touchRef else { touchRef = p; return }
        let cursor = CGPoint(x: start.x + p.x - ref.x, y: start.y + p.y - ref.y)
        if state == .armed {
            guard hypot(p.x - ref.x, p.y - ref.y) >= cfg.oneFingerStart else { return }
            state = .dragging
            log("touch: 1-finger drag")
            post(.leftMouseDown, at: start)
        }
        last = cursor
        post(.leftMouseDragged, at: cursor)
    }

    func touchLifted() {
        switch state {
        case .armed:
            log("touch: long-press right-click")
            post(.rightMouseDown, at: start); post(.rightMouseUp, at: start)
        case .dragging:
            post(.leftMouseUp, at: last)
        default: return
        }
        state = .liftClick
        liftTimer?.invalidate()
        liftTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in self?.finishLift() }
    }

    // A second finger landed: drop the one-finger gesture without clicking.
    func cancel() {
        switch state {
        case .scrolling: scroller.cancel()
        case .dragging: post(.leftMouseUp, at: last)
        default: break
        }
        state = .idle
    }

    private func finishLift() {
        liftTimer?.invalidate(); liftTimer = nil
        if state == .liftClick { state = .idle }
    }

    private func post(_ type: CGEventType, at p: CGPoint) {
        let button: CGMouseButton = type == .rightMouseDown || type == .rightMouseUp ? .right : .left
        let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        if type != .leftMouseDragged { ev?.setIntegerValueField(.mouseEventClickState, value: 1) }
        replay(ev)
    }

    private func replay(_ ev: CGEvent?) {
        guard let ev else { return }
        ev.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        ev.post(tap: .cghidEventTap)
    }

    private func beginScroll() {
        state = .scrolling
        log("touch: scroll")
        scroller.begin(at: start)
    }

    private func endScroll() {
        state = .idle
        scroller.end()
    }

    private func scroll(to loc: CGPoint) {
        let dx = loc.x - last.x, dy = loc.y - last.y
        last = loc
        scroller.move(dx: dx, dy: dy, speed: scrollSpeed)
    }
}
