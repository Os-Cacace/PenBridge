// Rotation: turns the built-in display to follow how the laptop is held. Main thread.
//
// The readings come from the laptop's accelerometer through the IntelISH kext (Intel
// Sensor Hub), which publishes them in IORegistry as AccelSample (RawX/Y/Z in micro-g,
// Windows sensor axes: X to the screen's right, Y to its top, and the axis that points
// up reads -1 g). Without that kext there is no sensor and auto-rotate stays off.
//
// The display is turned the way System Settings does it: kIOFBSetTransform on the
// built-in framebuffer. The pen and touch mapping follows through panelRotation.
import AppKit
import IOKit
import IOKit.graphics
import WidgetKit

final class AutoRotate {
    static let shared = AutoRotate()

    private var timer: Timer?
    private var sensor: io_service_t = 0
    private var lastSequence = -1, staleReads = 0
    private var candidate = -1, candidateSince = 0.0
    private var lastRotation = 0.0
    /// Shown in the settings panel.
    private(set) var status = "No orientation sensor found"
    var sensorAvailable: Bool { findSensor() != 0 }

    func settingsChanged() {
        let on = settingsModel.c.autoRotate && !settingsModel.c.paused
        if on && timer == nil {
            candidate = -1
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
            log("Touchintosh: auto-rotate on")
            reloadControl()
        } else if !on, let t = timer {
            t.invalidate(); timer = nil
            log("Touchintosh: auto-rotate off")
            reloadControl()
        }
    }

    /// Keeps the Control Center switch (controls/Controls.swift) showing the current state.
    private func reloadControl() {
        if #available(macOS 26.0, *) { ControlCenter.shared.reloadControls(ofKind: "com.oscacace.Touchintosh.autoRotate") }
    }

    private func findSensor() -> io_service_t {
        if sensor == 0 { sensor = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IntelISH")) }
        return sensor
    }

    /// The latest reading in g, or nil when there is no sensor or it has stopped updating.
    private func reading() -> (x: Double, y: Double, z: Double)? {
        let s = findSensor()
        guard s != 0, let sample = IORegistryEntryCreateCFProperty(s, "AccelSample" as CFString, nil, 0)?
                .takeRetainedValue() as? [String: Any] else { status = "No orientation sensor found"; return nil }
        func g(_ key: String) -> Double? {
            (sample[key] as? NSNumber).map { Double(Int64(truncatingIfNeeded: $0.uint64Value)) / 1e6 }
        }
        let sequence = (sample["Sequence"] as? NSNumber)?.intValue ?? 0
        staleReads = sequence == lastSequence ? staleReads + 1 : 0
        lastSequence = sequence
        guard staleReads < 10, let x = g("RawX"), let y = g("RawY"), let z = g("RawZ") else {
            status = "The orientation sensor stopped sending readings"; return nil
        }
        return (x, y, z)
    }

    /// The display angle for a reading, or nil when it should stay as it is: lying flat,
    /// held diagonally, or being moved.
    private func angle(_ r: (x: Double, y: Double, z: Double)) -> Int? {
        let total = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()
        guard total > 0.75, total < 1.25, abs(r.z) < 0.85 else { return nil }
        let ax = abs(r.x), ay = abs(r.y)
        guard max(ax, ay) > 0.5, abs(ax - ay) > 0.3 else { return nil }
        if ay > ax { return r.y < 0 ? 0 : 180 }
        // Confirmed on the Latitude 7410: +x up needs 90°, -x up needs 270°.
        return (r.x > 0) != settingsModel.c.autoRotateReverse ? 90 : 270
    }

    private func tick() {
        guard let r = reading() else { return }
        status = String(format: "Sensor: x %.2f  y %.2f  z %.2f g", r.x, r.y, r.z)
        guard let wanted = angle(r) else { candidate = -1; return }
        let now = CACurrentMediaTime()
        if wanted != candidate { candidate = wanted; candidateSince = now; return }
        // Held steady for a moment, and not right after the last turn.
        guard now - candidateSince > 0.6, now - lastRotation > 1.5 else { return }
        guard let display = builtInDisplayID(), Int(CGDisplayRotation(display).rounded()) != wanted else { return }
        lastRotation = now
        rotate(to: wanted)
    }

    private func builtInDisplayID() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8), count: UInt32 = 0
        CGGetOnlineDisplayList(8, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// The framebuffer that drives the built-in panel: the one with a backlight display under it.
    private func builtInFramebuffer() -> io_service_t {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOFramebuffer"), &iterator) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }
        var fallback: io_service_t = 0
        while case let fb = IOIteratorNext(iterator), fb != 0 {
            var children: io_iterator_t = 0
            var builtIn = false
            if IORegistryEntryCreateIterator(fb, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &children) == KERN_SUCCESS {
                while case let child = IOIteratorNext(children), child != 0 {
                    if IOObjectConformsTo(child, "AppleBacklightDisplay") != 0 { builtIn = true }
                    IOObjectRelease(child)
                }
                IOObjectRelease(children)
            }
            if builtIn {
                if fallback != 0 { IOObjectRelease(fallback) }
                return fb
            }
            let pixels = IORegistryEntryCreateCFProperty(fb, "IOFBCurrentPixelCount" as CFString, nil, 0)?.takeRetainedValue() as? Int ?? 0
            if pixels > 0 && fallback == 0 { fallback = fb } else { IOObjectRelease(fb) }
        }
        return fallback
    }

    func rotate(to degrees: Int) {
        // IOGraphicsTypes.h: kIOFBSetTransform with the transform in the upper 16 bits
        // (swap axes 0x10, invert X 0x20, invert Y 0x40).
        let transforms: [Int: UInt32] = [0: 0x00, 90: 0x30, 180: 0x60, 270: 0x50]
        guard let transform = transforms[degrees] else { return }
        let fb = builtInFramebuffer()
        guard fb != 0 else { log("Touchintosh: auto-rotate found no built-in framebuffer"); return }
        defer { IOObjectRelease(fb) }
        let result = IOServiceRequestProbe(fb, 0x400 | (transform << 16))
        log("Touchintosh: rotate display to \(degrees)°\(result == KERN_SUCCESS ? "" : String(format: " failed (0x%x)", result))")
        // The pen and touch mapping reads the display's rotation every 2 s; refresh it sooner.
        for delay in [0.4, 1.2] { DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { refreshSettings() } }
    }
}
