// Buttons: what each pen button does, per app, and the Buttons tab that sets it.
// Side buttons are handled on the input thread (sideButtonsUpdate in main.swift);
// the top button arrives over Bluetooth on the main thread (PenKeyListener).
import AppKit
import SwiftUI

/// The app in front, ignoring PenBridge itself so opening the panel doesn't change it. Main thread.
var frontBundleID: String?

func watchFrontApp() {
    let own = Bundle.main.bundleIdentifier
    func adopt(_ app: NSRunningApplication?) {
        guard let app, let id = app.bundleIdentifier, id != own else { return }
        frontBundleID = id
        settingsModel.frontAppName = app.localizedName ?? id
        pushConfig(settingsModel.c)
    }
    adopt(NSWorkspace.shared.frontmostApplication)
    NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                      object: nil, queue: .main) { note in
        adopt(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
    }
}

/// Runs a top button press. Main thread.
func topButtonPressed(_ button: PenButton) {
    guard !buttonTestActive else { return }
    let binding = settingsModel.c.buttonMap(for: frontBundleID)[button]
    if settingsModel.c.paused && binding.action != .pause { return }
    performButtonAction(binding)
}

/// Runs a press action. Main thread. Scroll and Eraser are held actions handled on the input thread.
func performButtonAction(_ binding: ButtonBinding) {
    log("PenBridge: button action \(binding.action.rawValue)")
    // Mission Control only takes ⌃-arrows that carry the fn and keypad flags a real arrow key has.
    let arrow: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
    switch binding.action {
    case .none, .scroll, .eraser: break
    case .rightClick: clickAtPointer(.right)
    case .middleClick: clickAtPointer(.center)
    case .toggleEraser: setEraserLatched(!settingsModel.eraserLatched)
    case .undo: sendKey(6, [.maskCommand])
    case .redo: sendKey(6, [.maskCommand, .maskShift])
    case .shortcut:
        if binding.shortcut.isSet {
            sendKey(CGKeyCode(binding.shortcut.keyCode), CGEventFlags(rawValue: UInt64(binding.shortcut.flags)))
        }
    case .accessibilityKeyboard: toggleAccessibilityKeyboard()
    case .missionControl: sendKey(126, arrow)
    case .appExpose: sendKey(125, arrow)
    case .showDesktop: sendKey(103, [.maskSecondaryFn])   // F11
    case .nextSpace: sendKey(124, arrow)
    case .previousSpace: sendKey(123, arrow)
    case .screenshot: sendKey(23, [.maskCommand, .maskShift])   // ⇧⌘5
    case .openSettings: menuBar.showPanel()
    case .pause: settingsModel.c.paused.toggle()
    }
}

func sendKey(_ keyCode: CGKeyCode, _ flags: CGEventFlags) {
    for down in [true, false] {
        guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else { continue }
        ev.flags = flags
        ev.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        ev.post(tap: .cghidEventTap)
    }
}

func clickAtPointer(_ button: CGMouseButton) {
    let p = CGEvent(source: nil)?.location ?? .zero
    let types: [CGEventType] = button == .right ? [.rightMouseDown, .rightMouseUp] : [.otherMouseDown, .otherMouseUp]
    for type in types {
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { continue }
        ev.setIntegerValueField(.mouseEventClickState, value: 1)
        ev.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        ev.post(tap: .cghidEventTap)
    }
}

/// Sticky eraser: the pen reports itself as an eraser until switched back. Main thread.
func setEraserLatched(_ on: Bool) {
    settingsModel.eraserLatched = on
    runOnInput {
        eraserLatched = on
        updateProximity()
    }
}

/// Sends the Accessibility Shortcut (⌥⌘F5). With only Accessibility Keyboard chosen under
/// System Settings → Accessibility → Shortcut, it shows and hides the keyboard directly.
/// (Selecting its input source doesn't change whether the keyboard is on screen.)
func toggleAccessibilityKeyboard() {
    sendKey(96, [.maskCommand, .maskAlternate, .maskSecondaryFn])
}

// MARK: - Buttons tab

struct ButtonsTab: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var test: ButtonTest
    /// nil edits the All Apps settings; otherwise the bundle ID of an app profile.
    @State private var editing: String?

    private var profileIndex: Int? {
        editing.flatMap { id in model.c.appProfiles.firstIndex { $0.bundleID == id } }
    }

    private var map: ButtonMap {
        get { profileIndex.map { model.c.appProfiles[$0].buttons } ?? model.c.buttons }
    }

    private func setMap(_ m: ButtonMap) {
        if let i = profileIndex { model.c.appProfiles[i].buttons = m } else { model.c.buttons = m }
    }

    private func binding(_ button: PenButton) -> Binding<ButtonBinding> {
        Binding(get: { map[button] }, set: { var m = map; m[button] = $0; setMap(m) })
    }

    private var addableApps: [NSRunningApplication] {
        let taken = Set(model.c.appProfiles.map(\.bundleID))
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil
                      && $0.bundleIdentifier != Bundle.main.bundleIdentifier && !taken.contains($0.bundleIdentifier!) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private var nowUsing: String {
        let hasProfile = model.c.appProfiles.contains { $0.bundleID == frontBundleID }
        return "\(model.frontAppName) uses \(hasProfile ? "its own settings" : "All Apps")."
    }

    var body: some View {
        Form {
            Section {
                Picker("Settings for", selection: $editing) {
                    Text("All Apps").tag(String?.none)
                    ForEach(model.c.appProfiles) { Text($0.name).tag(String?.some($0.bundleID)) }
                }
                HStack {
                    Menu("Add App") {
                        ForEach(addableApps, id: \.processIdentifier) { app in
                            Button(app.localizedName ?? app.bundleIdentifier!) {
                                let profile = AppProfile(bundleID: app.bundleIdentifier!, name: app.localizedName ?? app.bundleIdentifier!,
                                                         buttons: model.c.buttons)
                                model.c.appProfiles.append(profile)
                                editing = profile.bundleID
                            }
                        }
                    }
                    .fixedSize()
                    Spacer()
                    if let i = profileIndex {
                        Button("Remove \(model.c.appProfiles[i].name)", role: .destructive) {
                            model.c.appProfiles.remove(at: i)
                            editing = nil
                        }
                    }
                }
            } header: {
                Text("Apps")
            } footer: {
                Text("Apps you add start with a copy of All Apps and then keep their own settings. Add App lists apps that are open. \(model.frontAppName.isEmpty ? "" : nowUsing)")
            }

            Section {
                row(.lower)
                row(.upper)
                if map.lower.action == .scroll || map.upper.action == .scroll {
                    SliderRow(title: "Pen scroll speed", value: $model.c.penScrollSpeed, range: Config.speedRange, format: speedFormat)
                }
            } header: {
                Text("Side buttons")
            } footer: {
                Text("The lower button is the one nearest the tip.")
            }

            if PenButton.allCases.contains(where: { map[$0].action == .accessibilityKeyboard }) {
                Section {
                    Text("This sends the Accessibility Shortcut (⌥⌘F5). In System Settings → Accessibility → Shortcut, choose only Accessibility Keyboard so it shows and hides the keyboard directly.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Shortcut Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?Shortcut") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }

            Section {
                row(.topClick)
                row(.topDoubleClick)
                row(.topHold)
            } header: {
                Text("Top button")
            } footer: {
                Text(test.bluetoothConnected
                     ? "Connected over Bluetooth."
                     : "Works over Bluetooth. The pen disconnects when idle; a click reconnects it, so the first click after a while can be missed.")
            }

            Section {
                Button("Test Pen Buttons…") { model.testingButtons = true }
                if model.eraserLatched {
                    Button("Switch Eraser Off") { setEraserLatched(false) }
                }
            } footer: {
                Text("The test shows what each button sends.")
            }
        }
    }

    @ViewBuilder
    private func row(_ button: PenButton) -> some View {
        let b = binding(button)
        Picker(button.title, selection: b.action) {
            ForEach(button.choices) { Text($0.title).tag($0) }
        }
        if b.wrappedValue.action == .shortcut {
            ShortcutRecorder(shortcut: b.shortcut)
        }
    }
}

/// Records the next key combination pressed while it's listening.
struct ShortcutRecorder: View {
    @Binding var shortcut: KeyShortcut
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        LabeledContent("Shortcut") {
            Button(recording ? "Type the shortcut…" : shortcut.isSet ? shortcut.label : "Record") {
                recording ? stop() : start()
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .shift, .control, .option])
            if event.keyCode == 53 && mods.isEmpty { stop(); return nil }   // Esc cancels
            shortcut = KeyShortcut(keyCode: Int(event.keyCode), flags: Int(mods.rawValue),
                                   label: Self.label(mods, event))
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static func label(_ mods: NSEvent.ModifierFlags, _ event: NSEvent) -> String {
        var text = ""
        if mods.contains(.control) { text += "⌃" }
        if mods.contains(.option) { text += "⌥" }
        if mods.contains(.shift) { text += "⇧" }
        if mods.contains(.command) { text += "⌘" }
        let names: [UInt16: String] = [36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
                                       123: "←", 124: "→", 125: "↓", 126: "↑",
                                       122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
                                       98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        return text + (names[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "?").uppercased())
    }
}
