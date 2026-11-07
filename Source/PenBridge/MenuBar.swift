// MenuBar: the top bar icon and its panel, which holds every PenBridge setting.
// Runs on the main thread. Input handling stays on its own thread and only ever
// receives finished Config values through pushConfig.
import AppKit
import SwiftUI

// Live numbers live apart from the settings, so their updates redraw only the Status tab.
final class LiveBox: ObservableObject {
    @Published var value = LiveStatus()
}

final class SettingsModel: ObservableObject {
    @Published var c: Config {
        didSet {
            guard c != oldValue else { return }
            if !applyingStored { c.save(); pushConfig(c) }
            onChange?()
        }
    }
    let liveBox = LiveBox()
    var live: LiveStatus {
        get { liveBox.value }
        set { liveBox.value = newValue }
    }
    @Published var pinned = false
    @Published var testingButtons = false
    @Published var eraserLatched = false { didSet { onChange?() } }
    @Published var frontAppName = ""
    var onChange: (() -> Void)?
    var onClose: (() -> Void)?
    private var applyingStored = false

    init() { c = Config.load() }

    // A `defaults write` from outside: adopt it without writing it back.
    func updateFromDefaults(_ stored: Config) {
        guard stored != c else { return }
        applyingStored = true
        c = stored
        applyingStored = false
        pushConfig(stored)
    }

    func resetAll() { c = Config() }
}

// A borderless panel can't take keyboard focus unless it says so.
final class SettingsPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

final class MenuBarController: NSObject, NSWindowDelegate {
    private static let panelSize = NSSize(width: 420, height: 680)
    private let model: SettingsModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel = SettingsPanel(contentRect: NSRect(origin: .zero, size: MenuBarController.panelSize),
                                      styleMask: [.borderless], backing: .buffered, defer: true)
    private var clickMonitor: Any?

    init(model: SettingsModel) {
        self.model = model
        super.init()
        buildPanel()
        item.button?.target = self
        item.button?.action = #selector(toggle)
        model.onChange = { [weak self] in self?.updateIcon() }
        model.onClose = { [weak self] in self?.closePanel() }
        // Rotating the screen or plugging in a display moves the usable area.
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        updateIcon()
        // The input thread hasn't published anything yet, so show its permission state now.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { model.live.hasPermissions = hasPermissions }
    }

    private func updateIcon() {
        let name = model.c.paused ? "pencil.slash" : model.eraserLatched ? "eraser" : "pencil.tip"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "PenBridge")
            ?? NSImage(systemSymbolName: "pencil", accessibilityDescription: "PenBridge")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = model.c.paused ? "PenBridge is paused" : model.eraserLatched ? "PenBridge: eraser on" : "PenBridge"
    }

    func showPanel() {
        if !panel.isVisible { openPanel() }
    }

    private func buildPanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.closePanel() }

        let radius: CGFloat = 14
        let mask = NSImage(size: NSSize(width: radius * 2 + 1, height: radius * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.panelSize))
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = mask

        let host = NSHostingView(rootView: PanelView(model: model))
        host.sizingOptions = []
        host.frame = background.bounds
        host.autoresizingMask = [.width, .height]
        background.addSubview(host)
        panel.contentView = background
    }

    // Directly under the menu bar, centered on the icon, and always fully on screen.
    private func placePanel() {
        let mouse = NSEvent.mouseLocation
        var anchor = mouse
        if let button = item.button, let window = button.window {
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            let middle = NSPoint(x: rect.midX, y: rect.midY)
            if NSScreen.screens.contains(where: { $0.frame.contains(middle) }) { anchor = middle }
        }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let margin: CGFloat = 8
        let width = min(Self.panelSize.width, area.width - margin * 2)
        let height = min(Self.panelSize.height, area.height - margin * 2)
        let x = min(max(anchor.x - width / 2, area.minX + margin), area.maxX - width - margin)
        panel.setFrame(NSRect(x: x, y: area.maxY - margin - height, width: width, height: height), display: true)
    }

    @objc private func toggle() {
        if panel.isVisible { closePanel() } else { openPanel() }
    }


    private func openPanel() {
        statusWanted = true
        placePanel()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        // Clicks in other apps never reach this app, so watch for them directly.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.model.pinned else { return }
            self.closePanel()
        }
    }

    private func closePanel() {
        panel.orderOut(nil)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        statusWanted = false
        model.pinned = false
        model.testingButtons = false
    }

    @objc private func screensChanged() {
        if panel.isVisible { placePanel() }
    }

    func windowDidResignKey(_ notification: Notification) {
        if !model.pinned && panel.isVisible { closePanel() }
    }
}

// MARK: - Panel

enum PanelTab: String, CaseIterable, Identifiable {
    case pen = "Pen", buttons = "Buttons", touch = "Touch", gestures = "Gestures", status = "Status"
    var id: String { rawValue }
}

struct PanelView: View {
    @ObservedObject var model: SettingsModel
    @State var tab: PanelTab = .pen

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.testingButtons {
                Divider()
                ButtonTestView(test: buttonTest) { model.testingButtons = false }
            } else {
                Picker("", selection: $tab) {
                    ForEach(PanelTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                Divider()
                Group {
                    switch tab {
                    case .pen: PenTab(model: model)
                    case .buttons: ButtonsTab(model: model, test: buttonTest)
                    case .touch: TouchTab(model: model)
                    case .gestures: GesturesTab(model: model)
                    case .status: StatusTab(model: model, box: model.liveBox)
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.c.paused ? "pencil.slash" : "pencil.tip")
                .font(.title3)
                .foregroundStyle(model.c.paused ? Color.secondary : Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("PenBridge").font(.headline)
                Text(model.c.paused ? "Paused: pen and touch are plain mouse input" : "Running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.pinned.toggle()
            } label: {
                Image(systemName: model.pinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .help(model.pinned ? "Let this panel close when you click away" : "Keep this panel open while you test in another app")
            .accessibilityLabel(model.pinned ? "Unpin panel" : "Pin panel")
            Toggle("Pause PenBridge", isOn: Binding(get: { !model.c.paused }, set: { model.c.paused = !$0 }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(model.c.paused ? "Resume PenBridge" : "Pause PenBridge")
            Button {
                model.onClose?()
            } label: {
                Image(systemName: "xmark.circle.fill").font(.title3)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Close this panel")
            .accessibilityLabel("Close panel")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Shared rows

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range) { Text(title) }
                .labelsHidden()
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

let percentFormat: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
let speedFormat: (Double) -> String = { String(format: "%.1f×", $0) }
let pointsFormat: (Double) -> String = { "\(Int($0.rounded())) pt" }
let secondsFormat: (Double) -> String = { "\(Int(($0 * 1000).rounded())) ms" }

// MARK: - Pen tab

struct PenTab: View {
    @ObservedObject var model: SettingsModel
    @State private var padPressure = 0.0
    @State private var padIsTablet = false
    @State private var clearToken = 0

    var body: some View {
        Form {
            Section {
                Toggle("Pressure and tilt", isOn: $model.c.penEnabled)
            } footer: {
                Text("Off makes the pen a plain mouse pointer.")
            }

            Section("Try it") {
                PressurePad(clearToken: clearToken) { pressure, tablet in
                    padPressure = pressure
                    padIsTablet = tablet
                }
                .frame(height: 110)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Pressure test area. Draw here with the pen.")
                HStack {
                    Text(padIsTablet ? String(format: "Pressure %.2f", padPressure) : "Draw here with the pen")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { clearToken += 1 }
                }
            }

            Section("Pressure") {
                CurveGraph(config: model.c).frame(height: 70).accessibilityHidden(true)
                HStack {
                    Text("Feel")
                    Spacer()
                    Button("Soft") { model.c.pressureCurve = 0.6 }
                    Button("Normal") { model.c.pressureCurve = 1.0 }
                    Button("Firm") { model.c.pressureCurve = 1.8 }
                }
                SliderRow(title: "Curve", value: $model.c.pressureCurve, range: Config.curveRange,
                          note: "Below 1.00, light strokes get heavier. Above 1.00, you press harder for the same line.")
                SliderRow(title: "Full pressure at", value: $model.c.pressureMax, range: 0.2...1, format: percentFormat,
                          note: "Lower this to reach full pressure with less force.")
                SliderRow(title: "Lightest touch", value: $model.c.pressureMin, range: 0...0.5, format: percentFormat)
                SliderRow(title: "Pressure smoothing", value: $model.c.pressureSmoothing, range: 0...0.95, format: percentFormat,
                          note: "Higher is steadier, but pressure responds more slowly.")
            }

            Section("Stroke") {
                SliderRow(title: "Stroke smoothing", value: $model.c.positionSmoothing, range: 0...1, format: percentFormat,
                          note: "Reduces wobble in slow lines. Higher values add a little lag. 0% is the most direct.")
                Toggle("Report tilt to apps", isOn: $model.c.tiltEnabled)
            }

            Section("Palm rejection") {
                Toggle("Ignore touch while using the pen", isOn: $model.c.palmRejection)
                if model.c.palmRejection {
                    SliderRow(title: "Keep ignoring touch for", value: $model.c.palmDelay, range: 0...1, format: secondsFormat,
                              note: "Counted from when the pen leaves hover range.")
                }
            }
        }
    }
}

struct CurveGraph: View {
    let config: Config
    var body: some View {
        Canvas { context, size in
            var grid = Path()
            grid.move(to: CGPoint(x: 0, y: size.height)); grid.addLine(to: CGPoint(x: size.width, y: 0))
            context.stroke(grid, with: .color(.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            var curve = Path()
            for i in 0...60 {
                let raw = Int(Double(i) / 60 * 4095)
                let y = max(config.shapedPressure(raw: raw), i == 0 ? 0 : config.pressureMin)
                let p = CGPoint(x: Double(i) / 60 * size.width, y: size.height * (1 - y))
                if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
            }
            context.stroke(curve, with: .color(.accentColor), lineWidth: 2)
        }
    }
}

// A small canvas: stroke width follows the pressure apps actually receive.
struct PressurePad: NSViewRepresentable {
    let clearToken: Int
    let onSample: (Double, Bool) -> Void

    func makeNSView(context: Context) -> PadView {
        let view = PadView()
        view.onSample = onSample
        return view
    }

    func updateNSView(_ view: PadView, context: Context) {
        view.onSample = onSample
        if view.clearToken != clearToken {
            view.clearToken = clearToken
            view.segments.removeAll()
            view.needsDisplay = true
        }
    }
}

final class PadView: NSView {
    struct Segment { var from: CGPoint; var to: CGPoint; var width: CGFloat }
    var segments: [Segment] = []
    var clearToken = 0
    var onSample: ((Double, Bool) -> Void)?
    private var last = CGPoint.zero

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func add(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let tablet = event.subtype == .tabletPoint
        let pressure = Double(event.pressure)
        segments.append(Segment(from: last, to: p, width: 1 + 9 * CGFloat(pressure)))
        if segments.count > 3000 { segments.removeFirst(500) }
        last = p
        onSample?(pressure, tablet)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        last = convert(event.locationInWindow, from: nil)
        add(event)
    }
    override func mouseDragged(with event: NSEvent) { add(event) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setStroke()
        for s in segments {
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineWidth = s.width
            path.move(to: s.from)
            path.line(to: s.to)
            path.stroke()
        }
    }
}

// MARK: - Touch tab

struct TouchTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("PenBridge touch features", isOn: $model.c.touchEnabled)
            } footer: {
                Text("Off leaves only VoodooI2C's basic tap and drag.")
            }
            Section("One finger") {
                Toggle("Swipe to scroll", isOn: $model.c.oneFingerScroll)
                if model.c.oneFingerScroll {
                    SliderRow(title: "Movement before scrolling starts", value: $model.c.oneFingerStart, range: 2...40, format: pointsFormat,
                              note: "Lower feels quicker. Higher makes taps less likely to turn into scrolls.")
                }
                SliderRow(title: "Double-tap window", value: $model.c.doubleTapTime, range: 0.2...0.8, format: secondsFormat)
            }
            Section("Scrolling") {
                SliderRow(title: "Speed", value: $model.c.scrollSpeed, range: Config.speedRange, format: speedFormat)
                Toggle("Reverse direction", isOn: $model.c.reverseScroll)
                Toggle("Keep gliding after a flick", isOn: $model.c.momentum)
                if model.c.momentum {
                    SliderRow(title: "Glide", value: $model.c.momentumGlide, range: 0.85...0.99, format: percentFormat,
                              note: "Higher coasts for longer.")
                }
            }
            Section("Right-click") {
                Toggle("Two-finger tap", isOn: $model.c.twoFingerTap)
                LabeledContent("Press and hold", value: "Always on")
            }
        }
    }
}

// MARK: - Gestures tab

struct GesturesTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Two-finger scroll") {
                Toggle("Enabled", isOn: $model.c.twoFingerScroll)
                if model.c.twoFingerScroll {
                    SliderRow(title: "Movement before it starts", value: $model.c.twoFingerStart, range: 2...40, format: pointsFormat)
                }
            }
            Section("Pinch to zoom") {
                Toggle("Enabled", isOn: $model.c.pinchEnabled)
                if model.c.pinchEnabled {
                    Toggle("Smooth zoom", isOn: $model.c.smoothZoom)
                    Text(model.c.smoothZoom ? "Trackpad-style zoom, in apps that support it." : "Sends ⌘+ and ⌘−, which works in more apps but zooms in steps.")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.c.smoothZoom {
                        SliderRow(title: "Zoom speed", value: $model.c.zoomSpeed, range: 0.2...4, format: speedFormat)
                    }
                    SliderRow(title: "Spread before it starts", value: $model.c.pinchStart, range: 5...60, format: pointsFormat)
                }
            }
            Section("Rotate") {
                Toggle("Enabled", isOn: $model.c.rotateEnabled)
                if model.c.rotateEnabled {
                    SliderRow(title: "Turn before it starts", value: $model.c.rotateStart, range: 5...45, format: { "\(Int($0.rounded()))°" })
                }
            }
            Section("Swipes") {
                Toggle("Enabled", isOn: $model.c.swipeEnabled)
                if model.c.swipeEnabled {
                    SliderRow(title: "Distance to trigger", value: $model.c.swipeStart, range: 30...300, format: pointsFormat)
                }
            }
            if model.c.swipeEnabled {
                Section("Three fingers") {
                    actionPicker("Swipe left", $model.c.swipe3Left)
                    actionPicker("Swipe right", $model.c.swipe3Right)
                    actionPicker("Swipe up", $model.c.swipe3Up)
                    actionPicker("Swipe down", $model.c.swipe3Down)
                }
                Section("Four or more fingers") {
                    actionPicker("Swipe left", $model.c.swipe4Left)
                    actionPicker("Swipe right", $model.c.swipe4Right)
                    actionPicker("Swipe up", $model.c.swipe4Up)
                    actionPicker("Swipe down", $model.c.swipe4Down)
                }
            }
        }
    }

    private func actionPicker(_ title: String, _ binding: Binding<SwipeAction>) -> some View {
        Picker(title, selection: binding) {
            ForEach(SwipeAction.allCases) { Text($0.title).tag($0) }
        }
    }
}

// MARK: - Status tab

struct StatusTab: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var box: LiveBox
    @State private var confirmingReset = false

    var body: some View {
        Form {
            if !box.value.hasPermissions {
                Section("Permissions needed") {
                    Text("PenBridge needs Input Monitoring and Accessibility before it can start.")
                    Button("Open Input Monitoring") { openPrivacy("Privacy_ListenEvent") }
                    Button("Open Accessibility") { openPrivacy("Privacy_Accessibility") }
                }
            }
            Section("Pen") {
                LabeledContent("State", value: box.value.penTouching ? "Touching" : box.value.penInRange ? "Hovering" : "Away")
                LabeledContent("Reports", value: "\(box.value.penRate) per second")
                LabeledContent("Pressure", value: String(format: "%.2f", box.value.pressure))
                LabeledContent("Tilt", value: "\(box.value.tiltX)°, \(box.value.tiltY)°")
            }
            Section("Touch") {
                LabeledContent("Fingers", value: "\(box.value.fingers)")
                LabeledContent("Gesture", value: box.value.gesture)
                LabeledContent("Reports", value: "\(box.value.touchRate) per second")
            }
            Section {
                LabeledContent("Typical", value: String(format: "%.1f ms", box.value.delayMedian))
                LabeledContent("Slowest 5%", value: String(format: "%.1f ms", box.value.delayP95))
                LabeledContent("High-priority input", value: box.value.realtime ? "On" : "Off")
            } header: {
                Text("Delay reaching PenBridge")
            } footer: {
                Text("Measured while this panel is open, from the driver to PenBridge. Drawing on screen adds more that isn't counted here.")
            }
            Section("Maintenance") {
                Toggle("Detailed log", isOn: $model.c.verboseLog)
                Button("Open Log") {
                    NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/PenBridge.log"))
                }
                Button("Restart PenBridge") { restartPenBridge() }
                if confirmingReset {
                    HStack {
                        Text("Reset every setting?")
                        Spacer()
                        Button("Cancel") { confirmingReset = false }
                        Button("Reset", role: .destructive) { model.resetAll(); confirmingReset = false }
                    }
                } else {
                    Button("Reset All Settings…") { confirmingReset = true }
                }
            }
        }
    }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // launchd restarts it; a plain exit could wait out the agent's restart throttle.
    private func restartPenBridge() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["kickstart", "-k", "gui/\(getuid())/com.oscacace.penbridge"]
        try? task.run()
    }
}

// MARK: - Snapshots

// Draws each tab to a PNG off screen, for checking the layout without opening the panel.
func renderPanelSnapshots(to directory: String) {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let model = SettingsModel()
    var demo = LiveStatus()
    demo.hasPermissions = true; demo.realtime = true
    model.live = demo
    let screens = PanelTab.allCases.map { ($0.rawValue, false, $0) } + [("ButtonTest", true, PanelTab.pen)]
    for (name, testing, tab) in screens {
        model.testingButtons = testing
        let view = NSHostingView(rootView: PanelView(model: model, tab: tab).background(Color(nsColor: .windowBackgroundColor)))
        view.sizingOptions = []   // like the real panel: a fixed size
        view.frame = NSRect(x: 0, y: 0, width: 420, height: 680)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.backgroundColor = .windowBackgroundColor
        window.setFrameOrigin(NSPoint(x: -3000, y: -3000))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        // Drawn at 2x so the images stay sharp on Retina screens and in docs.
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width) * 2,
                                         pixelsHigh: Int(view.bounds.height) * 2, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { continue }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = URL(fileURLWithPath: directory).appendingPathComponent("panel-\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
