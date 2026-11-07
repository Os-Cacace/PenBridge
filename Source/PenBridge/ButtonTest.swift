// ButtonTest: a guided check of what each pen button sends, plus the listener for the
// top button, which reaches the Mac over Bluetooth as a small keyboard (HP Active Pen G3).
import AppKit
import IOKit.hid
import SwiftUI

/// Set while the test screen is showing; the input thread forwards pen button bits only then.
var buttonTestActive = false
var lastTestBits: UInt8 = 0

let buttonTest = ButtonTest()
let penKeys = PenKeyListener()

/// The status byte of pen report 6.
struct PenBits: Equatable {
    var raw: UInt8 = 0
    var tip: Bool { raw & 0x01 != 0 }
    var barrel: Bool { raw & 0x02 != 0 }
    var eraser: Bool { raw & 0x04 != 0 }
    var invert: Bool { raw & 0x08 != 0 }
    var inRange: Bool { raw & 0x20 != 0 }
    var buttonNames: [String] {
        var names: [String] = []
        if barrel { names.append("Barrel") }
        if eraser { names.append("Eraser") }
        if invert { names.append("Invert") }
        return names
    }
}

enum TestStep: Int, CaseIterable, Identifiable {
    case lowerHover, upperHover, lowerTouch, upperTouch, topClick, topDouble, topHold
    var id: Int { rawValue }
    var isSide: Bool { rawValue <= TestStep.upperTouch.rawValue }

    var title: String {
        switch self {
        case .lowerHover: return "Lower side button"
        case .upperHover: return "Upper side button"
        case .lowerTouch: return "Lower side button, touching"
        case .upperTouch: return "Upper side button, touching"
        case .topClick: return "Top button, one click"
        case .topDouble: return "Top button, double-click"
        case .topHold: return "Top button, hold"
        }
    }

    var instruction: String {
        switch self {
        case .lowerHover:
            return "Hold the pen about 1 cm above the drawing area below, without touching. Press and hold the side button nearest the tip for a second, then let go."
        case .upperHover:
            return "Hold the pen about 1 cm above the drawing area, without touching. Press and hold the side button farther from the tip for a second, then let go."
        case .lowerTouch:
            return "Rest the tip on the drawing area. Press and hold the lower side button for a second, let go, then lift the pen."
        case .upperTouch:
            return "Rest the tip on the drawing area. Press and hold the upper side button for a second, let go, then lift the pen."
        case .topClick:
            return "Click the button on the end of the pen once."
        case .topDouble:
            return "Double-click the button on the end of the pen."
        case .topHold:
            return "Press and hold the button on the end of the pen for about 2 seconds, then let go."
        }
    }
}

final class ButtonTest: ObservableObject {
    @Published var bits = PenBits()
    @Published var step: TestStep? = .lowerHover
    @Published var results: [TestStep: String] = [:]
    @Published var heard = ""          // what the current step has picked up so far
    @Published var bluetoothConnected = false
    private var seenBits: UInt8 = 0
    private var chords: [String] = []
    private var advance: DispatchWorkItem?

    func start() {
        results = [:]
        select(.lowerHover)
        buttonTestActive = true
        log("PenBridge buttontest: started")
    }

    func stop() {
        buttonTestActive = false
        advance?.cancel()
    }

    func select(_ s: TestStep?) {
        advance?.cancel()
        step = s
        seenBits = 0
        chords = []
        heard = ""
        if s == nil { log("PenBridge buttontest: finished") }
    }

    func skip() {
        guard let step else { return }
        heard = "Nothing detected"
        record(step, after: 0)
    }

    func penBits(_ raw: UInt8) {
        bits = PenBits(raw: raw)
        guard let step, step.isSide else { return }
        seenBits |= raw & 0x0E
        guard seenBits != 0 else { return }
        var text = PenBits(raw: seenBits).buttonNames.joined(separator: " + ")
        if step == .lowerTouch || step == .upperTouch { text += bits.tip ? ", tip down" : "" }
        if heard.isEmpty || !heard.hasPrefix(text) { heard = text }
        if raw & 0x0E == 0 { record(step, after: 1.0) } else { advance?.cancel() }
    }

    func key(_ chord: String) {
        guard buttonTestActive, let step, !step.isSide else { return }
        chords.append(chord)
        heard = chords.joined(separator: ", ")
        record(step, after: 1.5)   // a second click or a hold restarts the wait
    }

    private func record(_ s: TestStep, after delay: Double) {
        advance?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.step == s else { return }
            self.results[s] = self.heard
            log("PenBridge buttontest \(s.title): \(self.heard)")
            self.select(TestStep.allCases.first { $0.rawValue > s.rawValue && self.results[$0] == nil })
        }
        advance = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

// MARK: - Top button over Bluetooth

/// Listens to the pen's Bluetooth keyboard without taking it over, so its keys still
/// reach macOS as usual.
final class PenKeyListener {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var modifiers = Set<UInt32>()
    var onChord: ((String) -> Void)?
    var onTop: ((PenButton) -> Void)?

    func start() {
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x04F2, kIOHIDProductIDKey: 0x1850] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            Unmanaged<PenKeyListener>.fromOpaque(context!).takeUnretainedValue().handle(value)
        }, context)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { _, _, _, _ in
            log("PenBridge: pen Bluetooth buttons connected")
            buttonTest.bluetoothConnected = true
        }, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { _, _, _, _ in
            log("PenBridge: pen Bluetooth buttons disconnected")
            buttonTest.bluetoothConnected = false
        }, nil)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess { log("PenBridge: pen Bluetooth listener failed to open (\(result))") }
    }

    private func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element), usage = IOHIDElementGetUsage(element)
        let pressed = IOHIDValueGetIntegerValue(value) != 0
        // Keyboard arrays report "no key" and rollover codes; neither is a button.
        guard usage != 0, usage != 0xFFFF_FFFF, !(page == 0x07 && usage <= 3) else { return }
        log("PenBridge pen key page=0x\(String(page, radix: 16)) usage=0x\(String(usage, radix: 16)) \(pressed ? "down" : "up")")
        if page == 0x07 && (0xE0...0xE7).contains(usage) {
            if pressed { modifiers.insert(usage) } else { modifiers.remove(usage) }
            return
        }
        guard pressed else { return }
        let chord = modifierText() + Self.keyName(page: page, usage: usage)
        onChord?(chord)
        // The pen sends ⌘F20 for a click, ⌘F19 for a double-click and ⌘F18 for a hold.
        if page == 0x07 && (modifiers.contains(0xE3) || modifiers.contains(0xE7)) {
            switch usage {
            case 0x6F: onTop?(.topClick)
            case 0x6E: onTop?(.topDoubleClick)
            case 0x6D: onTop?(.topHold)
            default: break
            }
        }
    }

    private func modifierText() -> String {
        var text = ""
        if modifiers.contains(0xE0) || modifiers.contains(0xE4) { text += "⌃" }
        if modifiers.contains(0xE2) || modifiers.contains(0xE6) { text += "⌥" }
        if modifiers.contains(0xE1) || modifiers.contains(0xE5) { text += "⇧" }
        if modifiers.contains(0xE3) || modifiers.contains(0xE7) { text += "⌘" }
        return text
    }

    static func keyName(page: UInt32, usage: UInt32) -> String {
        if page == 0x07 {
            if (0x3A...0x45).contains(usage) { return "F\(usage - 0x3A + 1)" }
            if (0x68...0x73).contains(usage) { return "F\(usage - 0x68 + 13)" }
            if (0x04...0x1D).contains(usage) { return String(UnicodeScalar(UInt8(usage - 0x04) + 65)) }
        }
        return "page 0x\(String(page, radix: 16)) key 0x\(String(usage, radix: 16))"
    }
}

// MARK: - Screen

struct ButtonTestView: View {
    @ObservedObject var test: ButtonTest
    let onDone: () -> Void
    @State private var clearToken = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(action: onDone) { Label("Settings", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Spacer()
                Text("Pen Button Test").font(.headline)
                Spacer()
                Button("Start Over") { test.start(); clearToken += 1 }
                    .buttonStyle(.borderless)
            }

            VStack(spacing: 2) {
                ForEach(TestStep.allCases) { stepRow($0) }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    if let step = test.step {
                        Text(step.title).font(.headline)
                        Text(step.instruction).fixedSize(horizontal: false, vertical: true)
                        if !step.isSide && !test.bluetoothConnected {
                            Text("The pen isn't connected over Bluetooth right now. Click the top button once to wake it, or press Skip.")
                                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                        HStack {
                            Image(systemName: test.heard.isEmpty ? "ellipsis.circle" : "checkmark.circle.fill")
                                .foregroundStyle(test.heard.isEmpty ? Color.secondary : Color.green)
                            Text(test.heard.isEmpty ? "Waiting for the button…" : "Detected: \(test.heard)")
                                .fontWeight(test.heard.isEmpty ? .regular : .semibold)
                            Spacer()
                            Button("Skip") { test.skip() }
                        }
                    } else {
                        Label("All done", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(.green)
                        Text("The results are saved. Tell Claude you're done.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            HStack(spacing: 6) {
                indicator("In range", test.bits.inRange)
                indicator("Tip", test.bits.tip)
                indicator("Barrel", test.bits.barrel)
                indicator("Eraser", test.bits.eraser)
                indicator("Invert", test.bits.invert)
            }

            PressurePad(clearToken: clearToken) { _, _ in }
                .frame(minHeight: 90, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.4)))
                .overlay(alignment: .topLeading) {
                    Text("Drawing area").font(.caption).foregroundStyle(.secondary).padding(6)
                }
                .accessibilityLabel("Drawing area for the button test")
        }
        .padding(14)
        .onAppear { test.start() }
        .onDisappear { test.stop() }
    }

    private func stepRow(_ s: TestStep) -> some View {
        let result = test.results[s]
        let current = test.step == s
        return Button { test.select(s) } label: {
            HStack(spacing: 8) {
                Image(systemName: result != nil ? "checkmark.circle.fill" : current ? "arrow.right.circle.fill" : "circle")
                    .foregroundStyle(result != nil ? Color.green : current ? Color.accentColor : Color.secondary)
                Text(s.title).fontWeight(current ? .semibold : .regular)
                Spacer()
                Text(result ?? "").foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(current ? Color.accentColor.opacity(0.12) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(s.title)\(result.map { ", detected \($0)" } ?? "")")
    }

    private func indicator(_ title: String, _ on: Bool) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(on ? Color.green.opacity(0.85) : Color.secondary.opacity(0.15)))
            .foregroundStyle(on ? Color.white : Color.secondary)
            .accessibilityLabel("\(title) \(on ? "on" : "off")")
    }
}
