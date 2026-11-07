// PenBridge Installer: checks the laptop, installs PenBridge (no admin needed), and
// optionally patches the touchscreen driver in the OpenCore EFI through Driver/pentool.sh
// (admin password). When something doesn't match, "Copy for Claude" writes a prompt
// with this machine's details so Claude Code can adapt the installer (see CLAUDE.md).
import AppKit
import IOKit
import IOKit.kext
import SwiftUI

let penVendorID = 0x056A, penProductID = 0x4957
let agentLabel = "com.oscacace.penbridge"
let home = FileManager.default.homeDirectoryForCurrentUser
let appDestination = home.appendingPathComponent("Applications/PenBridge.app")
let agentPath = home.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
let penLog = home.appendingPathComponent("Library/Logs/PenBridge.log")
let backupDir = home.appendingPathComponent("Library/Application Support/PenBridge/EFI-Backups")

/// The folder that holds this app. Driver files next to the app win over the bundled
/// copies, so Claude can adapt them without rebuilding.
var packageFolder: URL { Bundle.main.bundleURL.deletingLastPathComponent() }
var isTranslocated: Bool { Bundle.main.bundlePath.contains("/AppTranslocation/") }

func driverFile(_ name: String) -> URL {
    let outside = packageFolder.appendingPathComponent("Driver/\(name)")
    if FileManager.default.fileExists(atPath: outside.path) { return outside }
    return Bundle.main.resourceURL!.appendingPathComponent("Driver/\(name)")
}

// MARK: - Checks

enum CheckState { case ok, warn, fail, unknown }

struct Check: Identifiable {
    let id: String
    var title: String
    var state: CheckState
    var detail: String
}

func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, error.localizedDescription) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

func openCoreVersion() -> String? {
    let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/options")
    defer { IOObjectRelease(entry) }
    guard entry != 0,
          let value = IORegistryEntryCreateCFProperty(entry, "4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:opencore-version" as CFString,
                                                      kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data
    else { return nil }
    return String(decoding: value, as: UTF8.self).trimmingCharacters(in: .controlCharacters)
}

func loadedKextVersion(_ id: String) -> String? {
    guard let info = KextManagerCopyLoadedKextInfo([id] as CFArray, nil)?.takeRetainedValue() as? [String: Any],
          let kext = info[id] as? [String: Any] else { return nil }
    return kext["CFBundleVersion"] as? String ?? "loaded"
}

/// The digitizer's I2C controller as an OpenCore DeviceProperties path, plus every
/// Wacom device found (for the Claude helper when the model differs).
func findDigitizer() -> (found: Bool, pciPath: String?, wacomDevices: [String]) {
    var wacom: [String] = []
    var pciPath: String?
    var found = false
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == KERN_SUCCESS else {
        return (false, nil, [])
    }
    defer { IOObjectRelease(iterator) }
    while case let service = IOIteratorNext(iterator), service != 0 {
        defer { IOObjectRelease(service) }
        func prop(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        guard let vendor = prop("VendorID") as? Int, vendor == penVendorID else { continue }
        let product = prop("ProductID") as? Int ?? 0
        let transport = prop("Transport") as? String ?? "?"
        wacom.append(String(format: "Wacom 0x%04X:0x%04X over %@", vendor, product, transport))
        guard product == penProductID, transport == "I2C", !found else { continue }
        found = true
        // Walk up to the PCI device of the I2C controller.
        var current = service
        IOObjectRetain(current)
        while true {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { IOObjectRelease(current); break }
            IOObjectRelease(current)
            current = parent
            if IOObjectConformsTo(current, "IOPCIDevice") != 0 {
                if let debug = IORegistryEntryCreateCFProperty(current, "pcidebug" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String {
                    let parts = debug.split(separator: ":").compactMap { Int($0) }
                    // Only a device on the root bus has a simple PciRoot path.
                    if parts.count == 3, parts[0] == 0 {
                        pciPath = String(format: "PciRoot(0x0)/Pci(0x%x,0x%x)", parts[1], parts[2])
                    }
                }
                IOObjectRelease(current)
                break
            }
        }
    }
    return (found, pciPath, wacom)
}

// MARK: - Model

enum Step: Int, CaseIterable, Identifiable {
    case check, penBridge, driver, permissions, finish
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .check: return "Check this Mac"
        case .penBridge: return "Install PenBridge"
        case .driver: return "Touchscreen driver"
        case .permissions: return "Permissions"
        case .finish: return "Finish"
        }
    }
    var symbol: String {
        switch self {
        case .check: return "checklist"
        case .penBridge: return "pencil.tip"
        case .driver: return "cpu"
        case .permissions: return "lock.shield"
        case .finish: return "flag.checkered"
        }
    }
}

final class InstallerModel: ObservableObject {
    @Published var step: Step = .check
    @Published var checks: [Check] = []
    @Published var pciPath: String?
    @Published var wacomDevices: [String] = []
    @Published var penBridgeInstalled = false
    @Published var penBridgeRunning = false
    @Published var permissionsGranted = false
    @Published var driverInfo: [String: String] = [:]
    @Published var driverLog: [String] = []
    @Published var driverBusy = false
    @Published var driverInstalledThisRun = false
    @Published var message: String?
    @Published var copiedForClaude = false
    private var timer: Timer?

    init() {
        runChecks()
        refreshPenBridge()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshPenBridge() }
    }

    var canInstallPenBridge: Bool { !checks.contains { $0.state == .fail && $0.id != "driver" } }

    func runChecks() {
        var list: [Check] = []
        let os = ProcessInfo.processInfo.operatingSystemVersion
        list.append(Check(id: "macos", title: "macOS 13 or later", state: os.majorVersion >= 13 ? .ok : .fail,
                          detail: "This Mac runs \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)."))
        var size = 0
        sysctlbyname("hw.optional.arm64", nil, &size, nil, 0)
        var arm: Int32 = 0
        sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0)
        list.append(Check(id: "intel", title: "Intel processor", state: arm == 1 ? .fail : .ok,
                          detail: arm == 1 ? "This is an Apple silicon Mac; PenBridge is for Intel hackintoshes." : "x86_64"))
        let oc = openCoreVersion()
        list.append(Check(id: "opencore", title: "Booted with OpenCore", state: oc == nil ? .warn : .ok,
                          detail: oc ?? "No OpenCore version found in NVRAM. PenBridge can still work; the driver step needs OpenCore."))
        let i2c = loadedKextVersion("com.alexandred.VoodooI2C")
        let hid = loadedKextVersion("com.alexandred.VoodooI2CHID")
        list.append(Check(id: "voodoo", title: "VoodooI2C loaded", state: i2c != nil && hid != nil ? .ok : .fail,
                          detail: i2c.map { "VoodooI2C \($0), VoodooI2CHID \(hid ?? "not loaded")" } ?? "VoodooI2C isn't loaded, so the touchscreen has no driver."))
        let digitizer = findDigitizer()
        pciPath = digitizer.pciPath
        wacomDevices = digitizer.wacomDevices
        let other = digitizer.wacomDevices.joined(separator: "; ")
        list.append(Check(id: "digitizer", title: "Wacom AES touchscreen (056A:4957)", state: digitizer.found ? .ok : .fail,
                          detail: digitizer.found ? "Found on I2C." : other.isEmpty ? "No Wacom touchscreen found." : "Found a different Wacom device: \(other). Use the Claude helper."))
        list.append(Check(id: "pci", title: "Touchscreen controller located", state: digitizer.pciPath != nil ? .ok : .warn,
                          detail: digitizer.pciPath ?? "Couldn't work out its PCI path. PenBridge works without it; the driver step needs it."))
        checks = list
    }

    func refreshPenBridge() {
        penBridgeInstalled = FileManager.default.fileExists(atPath: appDestination.path)
        penBridgeRunning = run("/usr/bin/pgrep", ["-f", "PenBridge.app/Contents/MacOS/PenBridge"]).status == 0
        // PenBridge logs "started" only once it has both permissions.
        if let text = try? String(contentsOf: penLog, encoding: .utf8) {
            let lines = text.split(separator: "\n").suffix(400)
            let last = lines.last { $0.contains("PenBridge started") || $0.contains("waiting for Input Monitoring") }
            permissionsGranted = penBridgeRunning && (last?.contains("PenBridge started") ?? false)
        } else {
            permissionsGranted = false
        }
    }

    // MARK: PenBridge

    func installPenBridge() {
        message = nil
        let fm = FileManager.default
        let source = Bundle.main.resourceURL!.appendingPathComponent("PenBridge.app")
        do {
            _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(agentLabel)"])
            try fm.createDirectory(at: appDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: appDestination.path) { try fm.removeItem(at: appDestination) }
            let copy = run("/usr/bin/ditto", [source.path, appDestination.path])
            guard copy.status == 0 else { throw NSError(domain: "PenBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: copy.output]) }
            _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", appDestination.path])
            let agent: [String: Any] = [
                "Label": agentLabel,
                "ProgramArguments": [appDestination.appendingPathComponent("Contents/MacOS/PenBridge").path],
                "RunAtLoad": true,
                "KeepAlive": true,
                "ThrottleInterval": 15,
                "ProcessType": "Interactive",
            ]
            try fm.createDirectory(at: agentPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
            try data.write(to: agentPath)
            let boot = run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", agentPath.path])
            guard boot.status == 0 else { throw NSError(domain: "PenBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "launchctl: \(boot.output)"]) }
            _ = run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                    ["-f", appDestination.path])
            message = "PenBridge is installed and starts at login."
        } catch {
            message = "Install failed: \(error.localizedDescription)"
        }
        refreshPenBridge()
    }

    func uninstallPenBridge() {
        _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(agentLabel)"])
        try? FileManager.default.removeItem(at: agentPath)
        try? FileManager.default.removeItem(at: appDestination)
        message = "PenBridge was removed. Its settings stay in case you reinstall."
        refreshPenBridge()
    }

    // MARK: Driver (admin)

    func runDriver(_ command: String) {
        guard !driverBusy else { return }
        driverBusy = true
        driverLog = []
        let tool = driverFile("pentool.sh").path
        let args = [tool, command, backupDir.path, NSUserName(), pciPath ?? "unknown"]
        let shellLine = (["/bin/zsh"] + args).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let escaped = shellLine.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped) 2>&1\" with administrator privileges without altering line endings"
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            let output = result?.stringValue ?? (error?[NSAppleScript.errorMessage] as? String ?? "The command didn't run.")
            DispatchQueue.main.async {
                self.driverBusy = false
                var info = self.driverInfo
                for line in output.split(separator: "\n").map(String.init) {
                    if line.hasPrefix("INFO "), let eq = line.firstIndex(of: "=") {
                        info[String(line[line.index(line.startIndex, offsetBy: 5)..<eq])] = String(line[line.index(after: eq)...])
                    } else if !line.isEmpty {
                        self.driverLog.append(line)
                    }
                }
                self.driverInfo = info
                if command == "install" && output.contains("DONE install") { self.driverInstalledThisRun = true }
                if command == "restore" && output.contains("DONE restore") { self.driverInstalledThisRun = true }
            }
        }
    }

    var driverFailed: Bool { driverLog.contains { $0.hasPrefix("FAIL") } }

    // MARK: Claude helper

    func copyForClaude() {
        var text = """
        I'm setting up PenBridge (pen and touchscreen support) on my hackintosh with the PenBridge Installer.
        The installer folder is: \(packageFolder.path)
        Read CLAUDE.md in that folder first and follow it. Don't change anything in my EFI without asking me first.

        What the installer found on this Mac:

        """
        for c in checks {
            text += "- \(c.title): \(c.state == .ok ? "OK" : c.state == .warn ? "WARNING" : c.state == .fail ? "FAILED" : "?") - \(c.detail)\n"
        }
        if !wacomDevices.isEmpty { text += "- Wacom devices: \(wacomDevices.joined(separator: "; "))\n" }
        if !driverInfo.isEmpty {
            text += "\nDriver diagnostics (pentool.sh):\n"
            for (k, v) in driverInfo.sorted(by: { $0.key < $1.key }) { text += "  \(k)=\(v)\n" }
        }
        if !driverLog.isEmpty { text += "\nLast driver tool output:\n" + driverLog.map { "  \($0)" }.joined(separator: "\n") + "\n" }
        text += "\nPlease work out what's different on this laptop and adapt the installer (Driver/patches.conf, Driver/pentool.sh or the PenBridge source) so it works here. Explain what you'll change before you change it."
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedForClaude = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.copiedForClaude = false }
    }
}

// MARK: - Views

struct InstallerView: View {
    @ObservedObject var model: InstallerModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(model.step.title).font(.title2.bold())
                        content
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                footer
            }
        }
        .frame(width: 720, height: 540)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 0) {
                    Text("PenBridge").font(.headline)
                    Text("Installer").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 14)
            ForEach(Step.allCases) { s in
                Button { model.step = s } label: {
                    Label(s.title, systemImage: s.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6).padding(.horizontal, 8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(model.step == s ? Color.accentColor.opacity(0.18) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            ClaudeButton(model: model)
        }
        .padding(16)
        .frame(width: 210)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .check: CheckStep(model: model)
        case .penBridge: PenBridgeStep(model: model)
        case .driver: DriverStep(model: model)
        case .permissions: PermissionsStep(model: model)
        case .finish: FinishStep(model: model)
        }
    }

    private var footer: some View {
        HStack {
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if model.step != .check {
                Button("Back") { model.step = Step(rawValue: model.step.rawValue - 1)! }
            }
            if model.step != .finish {
                Button("Continue") { model.step = Step(rawValue: model.step.rawValue + 1)! }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Done") { NSApp.terminate(nil) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}

struct ClaudeButton: View {
    @ObservedObject var model: InstallerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Doesn't match your laptop?").font(.caption.weight(.semibold))
            Text("Copies this Mac's details and instructions for Claude Code.").font(.caption2).foregroundStyle(.secondary)
            Button {
                model.copyForClaude()
            } label: {
                Label(model.copiedForClaude ? "Copied" : "Copy for Claude", systemImage: model.copiedForClaude ? "checkmark" : "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
    }
}

struct StatusIcon: View {
    let state: CheckState
    var body: some View {
        switch state {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .fail: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .unknown: Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
    }
}

struct CheckStep: View {
    @ObservedObject var model: InstallerModel
    var body: some View {
        Text("PenBridge is made for the Dell Latitude 7410 2-in-1 running macOS with OpenCore and VoodooI2C. These checks show whether this laptop matches.")
            .fixedSize(horizontal: false, vertical: true)
        if isTranslocated {
            Label("macOS is running this app from a temporary copy, so files next to it can't be read. Move the PenBridge Installer folder somewhere else (like Documents) and open it again.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
        VStack(spacing: 0) {
            ForEach(model.checks) { c in
                HStack(alignment: .top, spacing: 10) {
                    StatusIcon(state: c.state).font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.title).fontWeight(.medium)
                        Text(c.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
                Divider()
            }
        }
        HStack {
            Button("Check Again") { model.runChecks() }
            Spacer()
        }
        if model.checks.contains(where: { $0.state == .fail }) {
            Text("Something doesn't match. Use Copy for Claude in the sidebar, then paste it into Claude Code on this Mac to adapt the installer.")
                .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PenBridgeStep: View {
    @ObservedObject var model: InstallerModel
    var body: some View {
        Text("PenBridge is a small menu bar app. It adds pen pressure, tilt, the eraser, configurable pen buttons and touchscreen gestures. It installs into your user's Applications folder and starts at login. No administrator password is needed.")
            .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 10) {
            StatusIcon(state: model.penBridgeRunning ? .ok : model.penBridgeInstalled ? .warn : .unknown)
            Text(model.penBridgeRunning ? "Installed and running" : model.penBridgeInstalled ? "Installed, not running" : "Not installed")
        }
        HStack {
            Button(model.penBridgeInstalled ? "Reinstall PenBridge" : "Install PenBridge") { model.installPenBridge() }
                .controlSize(.large)
                .disabled(!model.canInstallPenBridge)
            if model.penBridgeInstalled {
                Button("Uninstall", role: .destructive) { model.uninstallPenBridge() }
            }
        }
        if !model.canInstallPenBridge {
            Text("Fix the failed checks first, or use the Claude helper.").foregroundStyle(.red)
        }
    }
}

struct DriverStep: View {
    @ObservedObject var model: InstallerModel
    var info: [String: String] { model.driverInfo }

    var body: some View {
        Text("Optional, but this is what makes the pen smooth. It changes the touchscreen driver in your OpenCore EFI:")
            .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 4) {
            Label("The pen is read before touch, so it can't get stuck", systemImage: "pencil.tip")
            Label("Polls every 1 ms while in use and every 8 ms when idle", systemImage: "speedometer")
            Label("Turns on polling for the touchscreen, which avoids the touch freeze", systemImage: "hand.tap")
        }
        .font(.callout)
        Text("The whole EFI/OC folder is backed up first, and Restore puts the original files back. Changes take effect after a restart. Keep a bootable USB with your EFI in case the Mac doesn't start.")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

        HStack {
            Button("Check Driver") { model.runDriver("diagnose") }
            Button("Install Driver Changes") { model.runDriver("install") }
                .controlSize(.large)
                .disabled(model.pciPath == nil || info["hid_state"] == nil || info["hid_state"] == "unknown")
            Button("Restore Original") { model.runDriver("restore") }
                .disabled(info["original_backup"] == nil || info["original_backup"] == "none")
            if model.driverBusy { ProgressView().controlSize(.small) }
        }
        Text("Check Driver asks for your password to read the EFI. It changes nothing.")
            .font(.caption).foregroundStyle(.secondary)

        if !info.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    row("Driver", hidText)
                    row("VoodooI2C", info["voodooi2c_version"] ?? "?")
                    row("Touchscreen polling", info["polling"] == "1" ? "On" : "Off")
                    row("OpenCore Vault", info["vault"] ?? "?")
                    row("Backup of the original", info["original_backup"].map { $0 == "none" ? "None yet" : $0 } ?? "?")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if !model.driverLog.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(model.driverLog.enumerated()), id: \.offset) { _, line in
                        Text(line.replacingOccurrences(of: "STEP ", with: "• ").replacingOccurrences(of: "DONE ", with: "✓ "))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("FAIL") ? Color.red : Color.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if model.driverFailed || info["hid_state"] == "unknown" {
            Text("This driver isn't one the installer knows. Nothing was changed. Use Copy for Claude to adapt the installer for it.")
                .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
        if model.driverInstalledThisRun {
            Label("Restart the Mac for the driver change to take effect.", systemImage: "arrow.clockwise.circle.fill")
                .foregroundStyle(.blue)
        }
    }

    private var hidText: String {
        switch info["hid_state"] {
        case "original": return "Original \(info["hid_build"] ?? "") - can be patched"
        case "patched": return "Patched \(info["hid_build"] ?? "")"
        case "unknown": return "Unknown version (\(info["hid_md5"]?.prefix(8) ?? "?")…)"
        default: return "?"
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary).frame(width: 170, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
        .font(.callout)
    }
}

struct PermissionsStep: View {
    @ObservedObject var model: InstallerModel
    var body: some View {
        Text("PenBridge needs two permissions. macOS will ask for them when PenBridge starts; if you missed the prompts, turn PenBridge on in both lists:")
            .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Input Monitoring: reads the pen and touchscreen.")
                Spacer()
                Button("Open") { openPrivacy("Privacy_ListenEvent") }
            }
            HStack {
                Text("Accessibility: adds pressure and gestures to input.")
                Spacer()
                Button("Open") { openPrivacy("Privacy_Accessibility") }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        HStack(spacing: 10) {
            StatusIcon(state: model.permissionsGranted ? .ok : .warn)
            Text(model.permissionsGranted ? "PenBridge has both permissions and is running." :
                    model.penBridgeRunning ? "Waiting for permissions…" : "PenBridge isn't running yet. Install it first.")
        }
        Text("The Input Monitoring prompt says the app can record keystrokes. PenBridge only reads the pen, touchscreen and its own Bluetooth pen button; it doesn't log or send what you type.")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct FinishStep: View {
    @ObservedObject var model: InstallerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summary("PenBridge installed and running", model.penBridgeRunning ? .ok : .warn)
            summary("Permissions granted", model.permissionsGranted ? .ok : .warn)
            summary(model.driverInstalledThisRun ? "Driver changed - restart to use it" : "Driver unchanged in this session",
                    model.driverInstalledThisRun ? .warn : .unknown)
        }
        Text("Click the pen icon in the menu bar for every setting: pressure, buttons per app, gestures and a pen button test. For the HP pen's top button, pair the pen in Bluetooth settings while it's in pairing mode.")
            .fixedSize(horizontal: false, vertical: true)
        if model.driverInstalledThisRun {
            Button("Restart Now…") {
                NSAppleScript(source: "tell application \"System Events\" to restart")?.executeAndReturnError(nil)
            }
        }
    }

    private func summary(_ text: String, _ state: CheckState) -> some View {
        HStack(spacing: 10) { StatusIcon(state: state); Text(text) }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "PenBridge Installer"
        window.contentView = NSHostingView(rootView: InstallerView(model: InstallerModel()))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// --snapshot <dir>: renders every step to PNG without showing a window (for checking layout).
func renderSnapshots(to dir: String) {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let model = InstallerModel()
    model.driverInfo = ["hid_state": "patched", "hid_build": "VoodooI2C 2.9.1", "voodooi2c_version": "2.9.1",
                        "polling": "1", "vault": "Optional", "original_backup": "none"]
    model.driverLog = ["STEP VoodooI2CHID was already patched", "DONE diagnose"]
    for step in Step.allCases {
        model.step = step
        let view = NSHostingView(rootView: InstallerView(model: model).background(Color(nsColor: .windowBackgroundColor)))
        view.sizingOptions = []
        view.frame = NSRect(x: 0, y: 0, width: 720, height: 540)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -3000, y: -3000))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        // Drawn at 2x so the images stay sharp on Retina screens and in docs.
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width) * 2,
                                         pixelsHigh: Int(view.bounds.height) * 2, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { continue }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("step-\(step.rawValue).png"))
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    renderSnapshots(to: CommandLine.arguments[i + 1])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
