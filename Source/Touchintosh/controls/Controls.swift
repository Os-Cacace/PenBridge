// Touchintosh's Control Center controls (macOS 26 and later). This is a WidgetKit
// extension embedded in Touchintosh.app. It reads and writes the app's own settings
// and tells the running app to pick the change up right away.
import AppIntents
import SwiftUI
import WidgetKit

private let appDomain = "com.oscacace.Touchintosh"
let autoRotateKind = "com.oscacace.Touchintosh.autoRotate"

@main
struct TouchintoshControls: WidgetBundle {
    var body: some Widget {
        AutoRotateControl()
    }
}

struct AutoRotateControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: autoRotateKind, provider: AutoRotateValue()) { isOn in
            ControlWidgetToggle("Auto-Rotate", isOn: isOn, action: SetAutoRotateIntent()) { on in
                Label(on ? "On" : "Off", systemImage: on ? "rectangle.landscape.rotate" : "lock.rotation")
            }
        }
        .displayName("Auto-Rotate")
        .description("Turns the screen when you turn the laptop.")
    }
}

struct AutoRotateValue: ControlValueProvider {
    var previewValue: Bool { false }
    func currentValue() async throws -> Bool {
        UserDefaults(suiteName: appDomain)?.bool(forKey: "autoRotate") ?? false
    }
}

struct SetAutoRotateIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Auto-Rotate"

    @Parameter(title: "On")
    var value: Bool

    func perform() async throws -> some IntentResult {
        UserDefaults(suiteName: appDomain)?.set(value, forKey: "autoRotate")
        // Touchintosh re-reads its settings every 2 s; this makes it immediate.
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.oscacace.Touchintosh.settingsChanged"), object: nil, userInfo: nil, deliverImmediately: true)
        return .result()
    }
}
