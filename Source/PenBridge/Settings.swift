// Settings: every PenBridge option in one place. Values live in the app's defaults
// domain (com.oscacace.PenBridge), so the menu bar panel and `defaults write` both work.
import Foundation

enum SwipeAction: String, Codable, CaseIterable, Identifiable {
    case none, nextSpace, previousSpace, missionControl, appExpose, showDesktop, back, forward
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Nothing"
        case .nextSpace: return "Next Space"
        case .previousSpace: return "Previous Space"
        case .missionControl: return "Mission Control"
        case .appExpose: return "App Exposé"
        case .showDesktop: return "Show Desktop"
        case .back: return "Back (⌘[)"
        case .forward: return "Forward (⌘])"
        }
    }
    init(from decoder: Decoder) throws {
        self = SwipeAction(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .none
    }
}

// MARK: Pen buttons

/// What a pen button does. Scroll and Eraser last while a side button is held;
/// everything else happens once per press.
enum ButtonAction: String, Codable, CaseIterable, Identifiable {
    case none, rightClick, middleClick, scroll, eraser, toggleEraser, undo, redo, shortcut,
         accessibilityKeyboard, missionControl, appExpose, showDesktop, nextSpace, previousSpace, screenshot,
         openSettings, pause
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Nothing"
        case .rightClick: return "Right-click"
        case .middleClick: return "Middle-click"
        case .scroll: return "Scroll while touching"
        case .eraser: return "Eraser while held"
        case .toggleEraser: return "Switch eraser on/off"
        case .undo: return "Undo (⌘Z)"
        case .redo: return "Redo (⇧⌘Z)"
        case .shortcut: return "Keyboard shortcut…"
        case .accessibilityKeyboard: return "Show/hide Accessibility Keyboard"
        case .missionControl: return "Mission Control"
        case .appExpose: return "App Exposé"
        case .showDesktop: return "Show Desktop"
        case .nextSpace: return "Next Space"
        case .previousSpace: return "Previous Space"
        case .screenshot: return "Screenshot (⇧⌘5)"
        case .openSettings: return "Open PenBridge settings"
        case .pause: return "Pause or resume PenBridge"
        }
    }
    /// Needs the button held down, which the top button can't report.
    var needsHold: Bool { self == .scroll || self == .eraser }
    init(from decoder: Decoder) throws {
        self = ButtonAction(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .none
    }
}

enum PenButton: String, CaseIterable, Identifiable {
    case lower, upper, topClick, topDoubleClick, topHold
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lower: return "Lower button"
        case .upper: return "Upper button"
        case .topClick: return "Click"
        case .topDoubleClick: return "Double-click"
        case .topHold: return "Press and hold"
        }
    }
    var isSide: Bool { self == .lower || self == .upper }
    var keyPath: WritableKeyPath<ButtonMap, ButtonBinding> {
        switch self {
        case .lower: return \.lower
        case .upper: return \.upper
        case .topClick: return \.topClick
        case .topDoubleClick: return \.topDoubleClick
        case .topHold: return \.topHold
        }
    }
    var choices: [ButtonAction] { isSide ? ButtonAction.allCases : ButtonAction.allCases.filter { !$0.needsHold } }
}

/// A recorded key combination. Modifier bits are the same in NSEvent and CGEvent flags.
struct KeyShortcut: Codable, Equatable {
    var keyCode = -1
    var flags = 0
    var label = ""
    var isSet: Bool { keyCode >= 0 }
}

struct ButtonBinding: Codable, Equatable {
    var action: ButtonAction
    var shortcut = KeyShortcut()
    init(_ action: ButtonAction) { self.action = action }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = (try? c.decode(ButtonAction.self, forKey: .action)) ?? .none
        shortcut = (try? c.decode(KeyShortcut.self, forKey: .shortcut)) ?? KeyShortcut()
    }
}

struct ButtonMap: Codable, Equatable {
    var lower = ButtonBinding(.scroll)
    var upper = ButtonBinding(.rightClick)
    var topClick = ButtonBinding(.undo)
    var topDoubleClick = ButtonBinding(.redo)
    var topHold = ButtonBinding(.missionControl)
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ButtonMap()
        lower = (try? c.decode(ButtonBinding.self, forKey: .lower)) ?? d.lower
        upper = (try? c.decode(ButtonBinding.self, forKey: .upper)) ?? d.upper
        topClick = (try? c.decode(ButtonBinding.self, forKey: .topClick)) ?? d.topClick
        topDoubleClick = (try? c.decode(ButtonBinding.self, forKey: .topDoubleClick)) ?? d.topDoubleClick
        topHold = (try? c.decode(ButtonBinding.self, forKey: .topHold)) ?? d.topHold
    }
    subscript(button: PenButton) -> ButtonBinding {
        get { self[keyPath: button.keyPath] }
        set { self[keyPath: button.keyPath] = newValue }
    }
}

/// Button settings for one app, used instead of the All Apps settings while it's in front.
struct AppProfile: Codable, Equatable, Identifiable {
    var bundleID: String
    var name: String
    var buttons = ButtonMap()
    var id: String { bundleID }
    init(bundleID: String, name: String, buttons: ButtonMap) {
        self.bundleID = bundleID; self.name = name; self.buttons = buttons
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        name = (try? c.decode(String.self, forKey: .name)) ?? bundleID
        buttons = (try? c.decode(ButtonMap.self, forKey: .buttons)) ?? ButtonMap()
    }
}

struct Config: Codable, Equatable {
    var paused = false

    // Pen
    var penEnabled = true
    var pressureCurve = 1.0        // exponent: below 1 softer, above 1 firmer
    var pressureSmoothing = 0.3    // how strongly pressure is averaged between events
    var pressureMin = 0.01         // lowest pressure while the tip touches
    var pressureMax = 1.0          // raw pressure treated as full pressure
    var positionSmoothing = 0.0    // stroke jitter filter, adds a little lag when above 0
    var tiltEnabled = true
    var palmRejection = true
    var palmDelay = 0.3            // seconds touch stays ignored after the pen was last seen
    var buttons = ButtonMap()
    var appProfiles: [AppProfile] = []
    var penScrollSpeed = 1.0

    // Touch
    var touchEnabled = true
    var oneFingerScroll = true
    var oneFingerStart = 12.0      // points a finger moves before a swipe scrolls
    var scrollSpeed = 1.0
    var reverseScroll = false
    var momentum = true
    var momentumGlide = 0.95       // speed kept per frame while coasting
    var doubleTapTime = 0.5
    var twoFingerTap = true

    // Gestures
    var twoFingerScroll = true
    var twoFingerStart = 10.0
    var pinchEnabled = true
    var pinchStart = 18.0
    var smoothZoom = true
    var zoomSpeed = 1.0
    var rotateEnabled = true
    var rotateStart = 15.0         // degrees
    var swipeEnabled = true
    var swipeStart = 90.0
    var swipe3Left = SwipeAction.nextSpace
    var swipe3Right = SwipeAction.previousSpace
    var swipe3Up = SwipeAction.missionControl
    var swipe3Down = SwipeAction.appExpose
    var swipe4Left = SwipeAction.nextSpace
    var swipe4Right = SwipeAction.previousSpace
    var swipe4Up = SwipeAction.missionControl
    var swipe4Down = SwipeAction.appExpose

    var verboseLog = false

    /// Pressure after the full-pressure point and curve, before smoothing and the minimum.
    func shapedPressure(raw: Int) -> Double {
        let x = min(max(Double(raw) / 4095.0 / max(pressureMax, 0.01), 0), 1)
        return pow(x, pressureCurve)
    }

    func buttonMap(for bundleID: String?) -> ButtonMap {
        appProfiles.first { $0.bundleID == bundleID }?.buttons ?? buttons
    }

    func swipeAction(fingers: Int, dx: Double, dy: Double) -> SwipeAction {
        let horizontal = abs(dx) > abs(dy)
        if fingers >= 4 {
            return horizontal ? (dx < 0 ? swipe4Left : swipe4Right) : (dy < 0 ? swipe4Up : swipe4Down)
        }
        return horizontal ? (dx < 0 ? swipe3Left : swipe3Right) : (dy < 0 ? swipe3Up : swipe3Down)
    }

    func clamped() -> Config {
        func fit(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(max(v, r.lowerBound), r.upperBound) }
        var c = self
        c.pressureCurve = fit(c.pressureCurve, Self.curveRange)
        c.pressureSmoothing = fit(c.pressureSmoothing, 0...0.95)
        c.pressureMin = fit(c.pressureMin, 0...0.5)
        c.pressureMax = fit(c.pressureMax, 0.2...1)
        c.positionSmoothing = fit(c.positionSmoothing, 0...1)
        c.palmDelay = fit(c.palmDelay, 0...1)
        c.penScrollSpeed = fit(c.penScrollSpeed, Self.speedRange)
        c.oneFingerStart = fit(c.oneFingerStart, 2...40)
        c.scrollSpeed = fit(c.scrollSpeed, Self.speedRange)
        c.momentumGlide = fit(c.momentumGlide, 0.85...0.99)
        c.doubleTapTime = fit(c.doubleTapTime, 0.2...0.8)
        c.twoFingerStart = fit(c.twoFingerStart, 2...40)
        c.pinchStart = fit(c.pinchStart, 5...60)
        c.zoomSpeed = fit(c.zoomSpeed, 0.2...4)
        c.rotateStart = fit(c.rotateStart, 5...45)
        c.swipeStart = fit(c.swipeStart, 30...300)
        return c
    }

    static let curveRange = 0.2...5.0
    static let speedRange = 0.2...5.0

    // MARK: Storage

    private static func plist(_ c: Config) -> [String: Any] {
        guard let data = try? PropertyListEncoder().encode(c),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [:] }
        return dict
    }

    // `defaults write` without a type stores a string, so a stored value is converted
    // to the type of its default. A value that cannot be converted is ignored.
    private static func coerce(_ stored: Any, like fallback: Any) -> Any? {
        if fallback is String { return stored as? String }
        if fallback is [Any] { return stored as? [Any] }
        if fallback is [String: Any] { return stored as? [String: Any] }
        let isBool = CFGetTypeID(fallback as CFTypeRef) == CFBooleanGetTypeID()
        if isBool {
            if let n = stored as? NSNumber { return n.boolValue }
            if let s = (stored as? String)?.lowercased() {
                if ["1", "true", "yes"].contains(s) { return true }
                if ["0", "false", "no"].contains(s) { return false }
            }
            return nil
        }
        if let n = stored as? NSNumber { return n.doubleValue }
        return (stored as? String).flatMap(Double.init)
    }

    static func migrate(_ defaults: UserDefaults = .standard) {
        // Earlier versions turned palm rejection off with touchWhilePen = true.
        if defaults.object(forKey: "touchWhilePen") != nil {
            if defaults.object(forKey: "palmRejection") == nil {
                defaults.set(!defaults.bool(forKey: "touchWhilePen"), forKey: "palmRejection")
            }
            defaults.removeObject(forKey: "touchWhilePen")
        }
        // "upperButton" was misnamed: it set the lower side button (the pen's eraser signal).
        if let old = defaults.string(forKey: "upperButton") {
            var c = load(defaults)
            c.buttons.lower.action = old == "eraser" ? .eraser : old == "off" ? .none : .scroll
            c.save(defaults)
            defaults.removeObject(forKey: "upperButton")
        }
    }

    static func load(_ defaults: UserDefaults = .standard) -> Config {
        var merged = plist(Config())
        for (key, fallback) in merged {
            guard let stored = defaults.object(forKey: key), let value = coerce(stored, like: fallback) else { continue }
            merged[key] = value
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: merged, format: .binary, options: 0),
              let config = try? PropertyListDecoder().decode(Config.self, from: data) else { return Config() }
        return config.clamped()
    }

    func save(_ defaults: UserDefaults = .standard) {
        for (key, value) in Config.plist(self) { defaults.set(value, forKey: key) }
    }
}

/// Speed-aware stroke filter (one-euro style): smooths jitter when the pen moves
/// slowly and follows closely when it moves fast. Strength 0 passes points through.
struct StrokeFilter {
    private var x = 0.0, y = 0.0, last = 0.0, primed = false

    mutating func reset() { primed = false }

    mutating func filter(x nx: Double, y ny: Double, time: Double, strength: Double) -> (x: Double, y: Double) {
        guard strength > 0, primed, time > last else {
            x = nx; y = ny; last = time; primed = true
            return (nx, ny)
        }
        let dt = time - last
        let speed = hypot(nx - x, ny - y) / dt
        let cutoff = 30 * pow(2.0 / 30, strength) + 0.02 * speed   // Hz
        let alpha = 1 / (1 + 1 / (2 * Double.pi * cutoff * dt))
        x += alpha * (nx - x); y += alpha * (ny - y); last = time
        return (x, y)
    }
}

/// Numbers the Status tab shows, published about twice a second while the panel is open.
struct LiveStatus: Equatable {
    var penRate = 0, touchRate = 0
    var delayMedian = 0.0, delayP95 = 0.0
    var pressure = 0.0
    var tiltX = 0, tiltY = 0
    var penInRange = false, penTouching = false
    var fingers = 0
    var gesture = "None"
    var hasPermissions = false
    var realtime = false
}
