// PenBridge: gives the Wacom AES pen (WCOM4957, driven by VoodooI2C) real tablet
// behaviour on macOS — pressure, tilt, eraser and proximity — by reading the pen's
// HID reports and annotating the cursor events VoodooI2C already generates.
// Settings.swift holds the options, MenuBar.swift the panel, Touch.swift the gestures.
import Foundation
import IOKit.hid
import CoreGraphics
import ApplicationServices
import AppKit

let vendorID = 0x056A, productID = 0x4957
let penReportID: UInt32 = 6
let verboseArgument = CommandLine.arguments.contains("-v")
var verbose: Bool { verboseArgument || cfg.verboseLog }

// The input thread's copy of the settings. Changes arrive through pushConfig.
var cfg: Config = { Config.migrate(); return Config.load() }()

// Tablet identity reported to apps in proximity / point events.
let deviceID: Int64 = 0x5701
let tabletID: Int64 = 0x4957
let pointerSerial: Int64 = 0x4957_0001
// NX tablet capability bits: deviceID | absX | absY | buttons | tiltX | tiltY | absZ | pressure
let capabilityMask: Int64 = 0x0001 | 0x0002 | 0x0004 | 0x0040 | 0x0080 | 0x0100 | 0x0200 | 0x0400

struct PenState {
    var inRange = false
    var tip = false
    var barrel = false
    var eraser = false     // eraser end touching
    var invert = false     // eraser end in range
    var x = 0, y = 0
    var pressure = 0       // 0...4095
    var tiltX = 0, tiltY = 0 // degrees, -90...90
    var lastReport = Date.distantPast
}

var pen = PenState()
var proximityPointerType: Int64 = 0   // 0 = out of proximity, 1 = pen, 3 = eraser
var leaveTimer: Timer?

// Marks events PenBridge posts itself, so its own event tap never drops them.
let syntheticMarker: Int64 = 0x5045_4E42   // "PENB"

let logHandle: FileHandle? = {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/PenBridge.log")
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    let h = try? FileHandle(forWritingTo: url); h?.seekToEndOfFile(); return h
}()
let logTime: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

// Pen/annotation chatter only with -v; touch and lifecycle lines always go to ~/Library/Logs/PenBridge.log.
// File writes happen on their own queue so they can never hold up the input thread.
let logQueue = DispatchQueue(label: "PenBridge.log", qos: .utility)

func log(_ s: @autoclosure () -> String) {
    let line = s()
    if !verbose && !line.hasPrefix("touch") && !line.hasPrefix("PenBridge") { return }
    let now = Date()
    logQueue.async { logHandle?.write(Data("\(logTime.string(from: now)) \(line)\n".utf8)) }
}

// MARK: - Proximity

func postProximity(enter: Bool, pointerType: Int64) {
    guard let ev = CGEvent(source: nil) else { return }
    ev.type = .tabletProximity
    ev.location = CGEvent(source: nil)?.location ?? .zero
    setProximityFields(ev, enter: enter, pointerType: pointerType)
    ev.post(tap: .cghidEventTap)
    lastProximityAnnounce = .distantPast
    log("proximity \(enter ? "enter" : "leave") type=\(pointerType)")
}

// Chromium (Chrome, Brave, Edge) only treats the pointer as a pen after seeing a
// proximity event in the view, and resets to mouse on any non-tablet mouse event.
// The standalone proximity event does not reliably reach its view, so a hover
// move is periodically re-sent as a mouse event with the tablet-proximity subtype.
var lastProximityAnnounce = Date.distantPast

func announceProximity(on ev: CGEvent) {
    ev.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletProximity.rawValue))
    setProximityFields(ev, enter: true, pointerType: proximityPointerType == 0 ? 1 : proximityPointerType)
    lastProximityAnnounce = Date()
}

func setProximityFields(_ ev: CGEvent, enter: Bool, pointerType: Int64) {
    ev.setIntegerValueField(.tabletProximityEventVendorID, value: Int64(vendorID))
    ev.setIntegerValueField(.tabletProximityEventTabletID, value: tabletID)
    ev.setIntegerValueField(.tabletProximityEventPointerID, value: pointerType == 3 ? 1 : 0)
    ev.setIntegerValueField(.tabletProximityEventDeviceID, value: deviceID)
    ev.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 1)
    ev.setIntegerValueField(.tabletProximityEventVendorPointerType, value: pointerType == 3 ? 0x080A : 0x0802)
    ev.setIntegerValueField(.tabletProximityEventVendorPointerSerialNumber, value: pointerSerial)
    ev.setIntegerValueField(.tabletProximityEventVendorUniqueID, value: pointerSerial)
    ev.setIntegerValueField(.tabletProximityEventCapabilityMask, value: capabilityMask)
    ev.setIntegerValueField(.tabletProximityEventPointerType, value: pointerType)
    ev.setIntegerValueField(.tabletProximityEventEnterProximity, value: enter ? 1 : 0)
}

// The digitizer's InRange flickers for a few ms at the edge of hover range, so
// entering is immediate but leaving waits briefly in case the pen comes back.
func updateProximity() {
    let erasing = eraserLatched
        || ((pen.invert || pen.eraser) && activeButtons.lower.action == .eraser)
        || (pen.barrel && activeButtons.upper.action == .eraser)
    let wanted: Int64 = pen.inRange ? (erasing ? 3 : 1) : 0
    if wanted != 0 {
        leaveTimer?.invalidate(); leaveTimer = nil
        if proximityPointerType != wanted {
            if proximityPointerType != 0 { postProximity(enter: false, pointerType: proximityPointerType) }
            postProximity(enter: true, pointerType: wanted)
            proximityPointerType = wanted
        }
    } else if proximityPointerType != 0 && leaveTimer == nil {
        leaveTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { _ in
            if !pen.inRange && proximityPointerType != 0 {
                postProximity(enter: false, pointerType: proximityPointerType)
                proximityPointerType = 0
            }
            leaveTimer = nil
        }
    }
}

// MARK: - HID input

// Pen report 6 (18 bytes), decoded from raw bytes: element value callbacks
// (IOHIDQueueAddElement) hang on the VoodooI2C device.
// [1] bit0 tip, bit1 barrel, bit2 eraser, bit3 invert, bit5 in range;
// [2..3] X, [4..5] Y, [6..7] pressure 0-4095, [16] X tilt, [17] Y tilt (signed degrees).
func handlePenReport(_ r: UnsafePointer<UInt8>, _ length: Int) {
    guard length >= 18 else { return }
    penReportCount &+= 1
    if buttonTestActive && r[1] != lastTestBits {
        let bits = r[1]
        lastTestBits = bits
        DispatchQueue.main.async { buttonTest.penBits(bits) }
    }
    if cfg.paused || !cfg.penEnabled { releasePen(); return }
    func u16(_ o: Int) -> Int { Int(r[o]) | Int(r[o + 1]) << 8 }
    let b = r[1]
    if b & 0x0E != lastButtonBits {
        lastButtonBits = b & 0x0E
        log("pen: buttons barrel=\(b >> 1 & 1) eraser=\(b >> 2 & 1) invert=\(b >> 3 & 1) tip=\(b & 1) inRange=\(b >> 5 & 1) raw=0x\(String(b, radix: 16)) pressure=\(u16(6))")
    }
    let inRange = b & 0x20 != 0, invert = b & 0x08 != 0
    pen.tip = b & 0x01 != 0
    pen.barrel = b & 0x02 != 0
    pen.eraser = b & 0x04 != 0
    pen.x = u16(2); pen.y = u16(4)
    pen.pressure = u16(6)
    pen.tiltX = Int(Int8(bitPattern: r[16])); pen.tiltY = Int(Int8(bitPattern: r[17]))
    pen.lastReport = Date()
    let statusChanged = inRange != pen.inRange || invert != pen.invert || (b & 0x0E) != (lastStatusByte & 0x0E)
    lastStatusByte = b
    pen.inRange = inRange; pen.invert = invert
    sideButtonsUpdate()
    if statusChanged { updateProximity() }
}

// Ends anything the pen is doing, for when PenBridge is paused or the pen is turned off.
func releasePen() {
    pen.tip = false; pen.barrel = false; pen.eraser = false; pen.invert = false
    sideButtonsUpdate()
    leaveTimer?.invalidate(); leaveTimer = nil
    pen.inRange = false
    if proximityPointerType != 0 {
        postProximity(enter: false, pointerType: proximityPointerType)
        proximityPointerType = 0
    }
}

var lastButtonBits: UInt8 = 0
var lastStatusByte: UInt8 = 0
/// Input thread copies: the button settings for the app in front, and the sticky eraser.
var activeButtons = ButtonMap()
var eraserLatched = false
var lowerWasDown = false, upperWasDown = false, lowerRightDown = false
/// Whether VoodooI2C's right-button press from the upper button was let through,
/// so its release is too.
var penRightDownPassed = false
let penMaxX = 30931.0, penMaxY = 17399.0

// The built-in panel's position and rotation, refreshed off the input thread (see
// refreshSettings). The digitizer belongs to this panel, whichever display is the main one.
var panelBounds = builtInDisplay().bounds
var panelRotation = builtInDisplay().rotation

func builtInDisplay() -> (bounds: CGRect, rotation: Double) {
    var ids = [CGDirectDisplayID](repeating: 0, count: 8)
    var count: UInt32 = 0
    CGGetOnlineDisplayList(8, &ids, &count)
    let id = ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
    return (CGDisplayBounds(id), CGDisplayRotation(id))
}

// Normalized digitizer coordinates to screen points, following display rotation.
func panelPoint(nx: Double, ny: Double) -> CGPoint {
    let x: Double, y: Double
    switch Int(panelRotation) {
    case 90: x = ny; y = 1 - nx
    case 180: x = 1 - nx; y = 1 - ny
    case 270: x = 1 - ny; y = nx
    default: x = nx; y = ny
    }
    return CGPoint(x: panelBounds.minX + x * panelBounds.width, y: panelBounds.minY + y * panelBounds.height)
}

// The lower side button puts the pen in eraser mode (invert while hovering, eraser while
// touching), and VoodooI2C sends no mouse events for that. The upper button is the barrel
// switch, which VoodooI2C turns into right-button events (see the event tap). Whatever
// either button is set to do is driven from pen reports here.
func sideButtonsUpdate() {
    let p = panelPoint(nx: Double(pen.x) / penMaxX, ny: Double(pen.y) / penMaxY)
    let lower = activeButtons.lower, upper = activeButtons.upper
    let lowerDown = pen.invert || pen.eraser
    let upperDown = pen.barrel
    let scrolling = (lower.action == .scroll && pen.eraser) || (upper.action == .scroll && upperDown && pen.tip)
    let erasing = (lower.action == .eraser && pen.eraser) || (upper.action == .eraser && upperDown && pen.tip)

    let wantRight = lower.action == .rightClick && lowerDown
    if wantRight != lowerRightDown {
        postPenMouse(wantRight ? .rightMouseDown : .rightMouseUp, at: p)
        lowerRightDown = wantRight
    }
    // Press actions fire once, on the main thread.
    if lowerDown && !lowerWasDown && !lower.action.needsHold && lower.action != .rightClick && lower.action != .none {
        DispatchQueue.main.async { performButtonAction(lower) }
    }
    if upperDown && !upperWasDown && !upper.action.needsHold && upper.action != .rightClick && upper.action != .none {
        DispatchQueue.main.async { performButtonAction(upper) }
    }
    lowerWasDown = lowerDown
    upperWasDown = upperDown

    if scrolling {
        if penScrolling { oneFinger.penMoved(p) } else { penScrolling = true; oneFinger.penBegan(p) }
    } else if penScrolling {
        penScrolling = false
        oneFinger.penEnded()
    }

    if erasing {
        postPenMouse(eraserDown ? .leftMouseDragged : .leftMouseDown, at: p)
        eraserDown = true
    } else if eraserDown {
        postPenMouse(.leftMouseUp, at: p)
        eraserDown = false
    }
}

func postPenMouse(_ type: CGEventType, at p: CGPoint) {
    let button: CGMouseButton = type == .rightMouseDown || type == .rightMouseUp ? .right : .left
    guard let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
    if type != .leftMouseDragged { ev.setIntegerValueField(.mouseEventClickState, value: 1) }
    ev.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
    ev.post(tap: .cghidEventTap)
}

// MARK: - Event annotation

var smoothedPressure = 0.0
var wasTouching = false
var eraserDown = false
var strokeFilter = StrokeFilter()

func normalizedPressure() -> Double {
    let touching = pen.tip || pen.eraser
    defer { wasTouching = touching }
    guard touching else { return 0 }
    let shaped = cfg.shapedPressure(raw: pen.pressure)
    // Start each stroke from the real value so smoothing never delays the first contact.
    smoothedPressure = wasTouching ? smoothedPressure + (1 - cfg.pressureSmoothing) * (shaped - smoothedPressure) : shaped
    // A touching tip always reports some pressure so light strokes still register.
    return max(smoothedPressure, cfg.pressureMin)
}

func annotate(_ ev: CGEvent, _ type: CGEventType) {
    if type == .mouseMoved && Date().timeIntervalSince(lastProximityAnnounce) > 0.5 {
        announceProximity(on: ev)
        return
    }
    let pressure: Double
    switch type {
    case .leftMouseDown, .leftMouseDragged, .rightMouseDown, .rightMouseDragged: pressure = normalizedPressure()
    default: pressure = 0
    }
    lastPressure = pressure
    if cfg.positionSmoothing > 0 && (type == .leftMouseDown || type == .leftMouseDragged) {
        if type == .leftMouseDown { strokeFilter.reset() }
        let loc = ev.location
        let f = strokeFilter.filter(x: loc.x, y: loc.y, time: Double(ev.timestamp) / 1e9, strength: cfg.positionSmoothing)
        ev.location = CGPoint(x: f.x, y: f.y)
    }
    var buttons: Int64 = 0
    if pen.tip || pen.eraser { buttons |= 1 }
    if pen.barrel { buttons |= 2 }

    ev.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
    ev.setDoubleValueField(.mouseEventPressure, value: pressure)
    ev.setIntegerValueField(.tabletEventPointX, value: Int64(pen.x))
    ev.setIntegerValueField(.tabletEventPointY, value: Int64(pen.y))
    ev.setIntegerValueField(.tabletEventPointZ, value: 0)
    ev.setIntegerValueField(.tabletEventPointButtons, value: buttons)
    ev.setDoubleValueField(.tabletEventPointPressure, value: pressure)
    ev.setDoubleValueField(.tabletEventTiltX, value: cfg.tiltEnabled ? Double(pen.tiltX) / 90.0 : 0)
    ev.setDoubleValueField(.tabletEventTiltY, value: cfg.tiltEnabled ? Double(pen.tiltY) / 90.0 : 0)
    ev.setDoubleValueField(.tabletEventRotation, value: 0)
    ev.setDoubleValueField(.tabletEventTangentialPressure, value: 0)
    ev.setIntegerValueField(.tabletEventDeviceID, value: deviceID)
    if verbose { log("annotate type=\(type.rawValue) p=\(String(format: "%.3f", pressure)) tilt=\(pen.tiltX),\(pen.tiltY) btn=\(buttons)") }
}

// Only events that come from the pen get tablet data; finger touches stay plain mouse events.
func penIsActive() -> Bool {
    (pen.inRange || proximityPointerType != 0) && Date().timeIntervalSince(pen.lastReport) < 0.1
}

// MARK: - Setup

let touch = TouchGestures()
let oneFinger = OneFingerScroll()
var penScrolling = false
var penReportCount = 0, touchReportCount = 0
var lastPressure = 0.0
var eventDelays: [Double] = []
var statusWanted = false     // set by the panel while it is open
var hasPermissions = false, realtimePolicyOn = false
let settingsModel = SettingsModel()
touch.onOneFinger = { oneFinger.touchMoved($0) }
var leftButtonDown = false

// When a second finger lands during a one-finger drag, release the drag so the
// gesture does not also move or select things.
touch.onFingerCountChange = { old, new in
    if new >= 2 { oneFinger.cancel() }
    if old == 1 && new == 0 { oneFinger.touchLifted() }
    if old < 2 && new >= 2 && leftButtonDown {
        let loc = CGEvent(source: nil)?.location ?? .zero
        if let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: loc, mouseButton: .left) {
            up.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            up.post(tap: .cghidEventTap)
        }
        leftButtonDown = false
        log("touch: released one-finger drag for a \(new)-finger gesture")
    }
}

// Renders the panel to PNGs and exits, without touching the digitizer or the lock.
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    renderPanelSnapshots(to: CommandLine.arguments[i + 1])
    exit(0)
}

// One instance only: two would each annotate events and post every gesture twice.
// Decided here, before the digitizer is opened, so exiting is safe. The LaunchAgent
// waits for the lock; a copy opened from the app icon just quits. The lock is released
// by the kernel when the holder exits.
let lockPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/com.oscacace.PenBridge.lock").path
let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o644)
if lockFD >= 0 && flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == "com.oscacace.penbridge" {
        log("PenBridge: waiting for another running copy to quit")
        flock(lockFD, LOCK_EX)
    } else {
        log("PenBridge: already running, this copy is quitting")
        logQueue.sync {}
        exit(0)
    }
}

let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                            .rightMouseDown, .rightMouseUp, .rightMouseDragged, .mouseMoved]
let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
var tapPort: CFMachPort?
var manager: IOHIDManager?
var inputRunLoop: CFRunLoop?
let settingsTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))

// All input state lives on one thread, so nothing here needs locks. WindowServer
// waits for the tap's answer on every mouse event, so this thread runs as real-time.
func setInputThreadPriority() {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    func ticks(_ ms: Double) -> UInt32 { UInt32(ms * 1_000_000 * Double(timebase.denom) / Double(timebase.numer)) }
    var policy = thread_time_constraint_policy_data_t(period: ticks(4), computation: ticks(0.5), constraint: ticks(2), preemptible: 1)
    let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &policy) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            thread_policy_set(mach_thread_self(), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
        }
    }
    realtimePolicyOn = result == KERN_SUCCESS
    log("PenBridge: input thread real-time policy \(realtimePolicyOn ? "on" : "failed (\(result))")")
}

// Hands new settings to the input thread, which owns all input state.
// Main thread only: it also picks the button settings for the app in front.
func pushConfig(_ c: Config) {
    let map = c.buttonMap(for: frontBundleID)
    guard let loop = inputRunLoop else { cfg = c; activeButtons = map; return }
    CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
        let was = cfg
        cfg = c
        if (c.paused && !was.paused) || (!c.penEnabled && was.penEnabled) { releasePen() }
        if (c.paused && !was.paused) || (!c.touchEnabled && was.touchEnabled) { touch.reset() }
        if map != activeButtons {
            activeButtons = map
            sideButtonsUpdate()   // ends anything the old setting was holding
            updateProximity()
        }
    }
    CFRunLoopWakeUp(loop)
}

func runOnInput(_ block: @escaping () -> Void) {
    guard let loop = inputRunLoop else { block(); return }
    CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, block)
    CFRunLoopWakeUp(loop)
}

// Runs off the input thread, since these calls can block on other processes. It also
// picks up `defaults write` changes, so the panel and the command line stay in step.
func refreshSettings() {
    let stored = Config.load()
    let display = builtInDisplay()
    DispatchQueue.main.async { settingsModel.updateFromDefaults(stored) }
    guard let loop = inputRunLoop else { return }
    CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
        panelBounds = display.bounds
        panelRotation = display.rotation
    }
    CFRunLoopWakeUp(loop)
}

func publishStatus() {
    let pens = penReportCount, touches = touchReportCount
    penReportCount = 0; touchReportCount = 0
    defer { eventDelays.removeAll(keepingCapacity: true) }
    guard statusWanted else { return }
    let delays = eventDelays.sorted()
    var s = LiveStatus()
    s.penRate = pens * 2; s.touchRate = touches * 2
    if !delays.isEmpty {
        s.delayMedian = delays[delays.count / 2]
        s.delayP95 = delays[min(delays.count - 1, delays.count * 95 / 100)]
    }
    s.pressure = pen.tip || pen.eraser ? lastPressure : 0
    s.tiltX = pen.tiltX; s.tiltY = pen.tiltY
    s.penInRange = pen.inRange; s.penTouching = pen.tip || pen.eraser
    s.fingers = touch.fingerCount
    s.gesture = touch.gestureName
    s.hasPermissions = hasPermissions
    s.realtime = realtimePolicyOn
    DispatchQueue.main.async { settingsModel.live = s }
}

func startInput() {
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                      eventsOfInterest: mask, callback: { _, type, ev, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = tapPort { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(ev)
        }
        if statusWanted && eventDelays.count < 2000 {
            eventDelays.append(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- ev.timestamp) / 1e6)
        }
        if cfg.paused { return Unmanaged.passUnretained(ev) }
        let synthetic = ev.getIntegerValueField(.eventSourceUserData) == syntheticMarker
        var type = type
        // VoodooI2C turns the upper side button into right-button events. Unless that button
        // is set to Right-click, hold them back; a release always follows its press through.
        if !synthetic && penIsActive() && (type == .rightMouseDown || type == .rightMouseUp || type == .rightMouseDragged) {
            switch type {
            case .rightMouseDown:
                penRightDownPassed = activeButtons.upper.action == .rightClick
                if !penRightDownPassed { return nil }
            case .rightMouseUp:
                let passed = penRightDownPassed
                penRightDownPassed = false
                if !passed { return nil }
            default:
                if !penRightDownPassed {
                    if penScrolling { return nil }
                    // Still move the pointer while the button is held.
                    ev.type = .mouseMoved
                    ev.setIntegerValueField(.mouseEventButtonNumber, value: 0)
                    type = .mouseMoved
                }
            }
        }
        if penScrolling && !synthetic && (type == .leftMouseDown || type == .leftMouseDragged) {
            return nil   // the pen is scrolling (see penScrollUpdate); mouse-ups still pass
        } else if penIsActive() {
            annotate(ev, type)
        } else if !synthetic && !touch.multiFingerActive
                    && (oneFinger.state != .idle
                        || cfg.oneFingerScroll && (type == .leftMouseDown || type == .rightMouseDown) && touch.oneFingerActive) {
            guard let out = oneFinger.handle(type, ev) else { return nil }
            if type == .leftMouseUp { leftButtonDown = false }
            return Unmanaged.passUnretained(out)
        } else if touch.multiFingerActive && ev.getIntegerValueField(.eventSourceUserData) != syntheticMarker {
            // Hold back stray one-finger clicks/drags during a gesture. Mouse-ups always
            // pass: dropping one leaves macOS thinking the button is held forever.
            switch type {
            case .leftMouseDown, .leftMouseDragged: return nil
            default: break
            }
        }
        if type == .leftMouseDown { leftButtonDown = true }
        if type == .leftMouseUp { leftButtonDown = false }
        return Unmanaged.passUnretained(ev)
    }, userInfo: nil) else {
        print("PenBridge: cannot create the event tap. Grant Accessibility in System Settings → Privacy & Security.")
        exit(1)
    }
    tapPort = tap
    let loop: CFRunLoop = CFRunLoopGetCurrent()
    inputRunLoop = loop
    CFRunLoopAddSource(loop, CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    touch.startWatchdog()
    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in publishStatus() }

    settingsTimer.schedule(deadline: .now() + 2, repeating: 2)
    settingsTimer.setEventHandler { refreshSettings() }
    settingsTimer.resume()

    // Opened last and kept open for the life of the process (see the permission note above).
    let hid = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    manager = hid
    IOHIDManagerSetDeviceMatching(hid, [kIOHIDVendorIDKey: vendorID, kIOHIDProductIDKey: productID] as CFDictionary)
    IOHIDManagerRegisterInputReportCallback(hid, { _, _, _, _, reportID, report, length in
        if reportID == penReportID { handlePenReport(report, length) }
        else { touch.handleReport(reportID, report, length) }
    }, nil)
    IOHIDManagerScheduleWithRunLoop(hid, loop, CFRunLoopMode.defaultMode.rawValue)
    let openResult = IOHIDManagerOpen(hid, IOOptionBits(kIOHIDOptionsTypeNone))
    if openResult != kIOReturnSuccess {
        log(String(format: "PenBridge: cannot open the digitizer (0x%08X)", openResult))
    }
}

let inputThread = Thread {
    // Wait for both permissions before touching the digitizer. Repeatedly opening the
    // VoodooI2C HID device and exiting (as a permission-failure restart loop does)
    // wedges its kernel HID connection until reboot, so never exit once it is open.
    let accessibilityPrompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    var prompted = false
    while !(CGPreflightListenEventAccess() && AXIsProcessTrusted()) {
        if !prompted {
            log("PenBridge: waiting for Input Monitoring and Accessibility permission")
            if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
            if !AXIsProcessTrusted() { AXIsProcessTrustedWithOptions(accessibilityPrompt) }
            prompted = true
        }
        Thread.sleep(forTimeInterval: 3)
    }
    hasPermissions = true
    setInputThreadPriority()
    startInput()
    print("PenBridge running")
    log("PenBridge started")
    // Bounded runs so autoreleased objects get drained on this secondary thread.
    while true {
        autoreleasepool { _ = CFRunLoopRunInMode(.defaultMode, 1, false) }
    }
}
inputThread.name = "PenBridge input"
inputThread.qualityOfService = .userInteractive
inputThread.start()

// The main thread only runs the menu bar panel; input never waits on the UI.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let menuBar = MenuBarController(model: settingsModel)
penKeys.onChord = { buttonTest.key($0) }
penKeys.onTop = { topButtonPressed($0) }
watchFrontApp()
penKeys.start()
app.run()
