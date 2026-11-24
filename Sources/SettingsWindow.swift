import AppKit
import Observation
import SwiftUI

/// What the settings window reads and changes; the app delegate wires it up.
struct SettingsActions {
    var status: () -> SetupStatus
    var bool: (String) -> Bool
    var setBool: (String, Bool) -> Void
    var string: (String) -> String
    var setString: (String, String) -> Void
    var opensAtLogin: () -> Bool
    var setOpensAtLogin: (Bool) -> Void
    /// Called after a setting changes in the defaults.
    var settingsChanged: () -> Void
    /// These two run off the main thread.
    var turnOffGestures: () -> (ok: Bool, output: String)
    var restoreGestures: () -> (ok: Bool, output: String)
    var openSetup: () -> Void
    var openKeyboardShortcuts: () -> Void
    var rescan: () -> Void
    /// Nil in a development build, which does not update itself.
    var updates: UpdateActions? = nil
}

struct UpdateActions {
    var check: () -> Void
    var checksAutomatically: () -> Bool
    var setChecksAutomatically: (Bool) -> Void
}

/// The settings window's state: the defaults as they are, and the Mac's state read again while
/// the window is open (permissions and gestures change in System Settings).
@Observable
final class SettingsModel {
    private(set) var status: SetupStatus
    /// Bumped when a setting changes, so the views read it again.
    private(set) var version = 0
    private(set) var busy = false
    /// The message from the last change to macOS's gestures, if there is one.
    private(set) var message: String?

    @ObservationIgnored let actions: SettingsActions

    init(actions: SettingsActions) {
        self.actions = actions
        status = actions.status()
    }

    func refresh() {
        let fresh = actions.status()
        if fresh != status { status = fresh }
    }

    func bool(_ key: String) -> Bool {
        _ = version
        return actions.bool(key)
    }

    func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { self.bool(key) }, set: { self.set(key, $0) })
    }

    func set(_ key: String, _ value: Bool) {
        actions.setBool(key, value)
        changed()
    }

    func string(_ key: String) -> Binding<String> {
        Binding(get: {
            _ = self.version
            return self.actions.string(key)
        }, set: {
            self.actions.setString(key, $0)
            self.changed()
        })
    }

    var opensAtLogin: Binding<Bool> {
        Binding(get: {
            _ = self.version
            return self.actions.opensAtLogin()
        }, set: {
            self.actions.setOpensAtLogin($0)
            self.version += 1
        })
    }

    var checksForUpdates: Binding<Bool> {
        Binding(get: {
            _ = self.version
            return self.actions.updates?.checksAutomatically() ?? false
        }, set: {
            self.actions.updates?.setChecksAutomatically($0)
            self.version += 1
        })
    }

    func turnOffGestures() { run(actions.turnOffGestures) }
    func restoreGestures() { run(actions.restoreGestures) }

    private func run(_ change: @escaping () -> (ok: Bool, output: String)) {
        guard !busy else { return }
        busy = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = change()
            DispatchQueue.main.async {
                self.busy = false
                self.message = result.ok ? "If a four-finger swipe still acts as before, log out and back in." : result.output
                self.refresh()
            }
        }
    }

    private func changed() {
        actions.settingsChanged()
        version += 1
    }
}

/// The settings window: one instance, brought forward when opened again.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let size = CGSize(width: 520, height: 680)

    let model: SettingsModel
    private var window: NSWindow?
    private var poll: Timer?
    var onClose: () -> Void = {}

    init(model: SettingsModel) {
        self.model = model
        super.init()
    }

    var isOpen: Bool { window != nil }

    func show() {
        if self.window == nil { AppWindows.opened() }
        let window = self.window ?? makeWindow()
        self.window = window
        model.refresh()
        if poll == nil {
            poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.model.refresh() }
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "\(Flavor.name) Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let host = NSHostingView(rootView: SettingsView(model: model))
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(Self.size)
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        poll?.invalidate()
        poll = nil
        window?.contentView = nil
        window = nil
        AppWindows.closed()
        onClose()
    }
}

// MARK: Views

private struct SettingsView: View {
    let model: SettingsModel
    @State private var hovered: GestureDemo?
    @State private var hoverStart = Date()
    /// The gesture last pointed at, held still once the pointer leaves.
    @State private var shown = GestureDemo.slide

    var body: some View {
        Form {
            Section("General") {
                Toggle("Use four-finger gestures", isOn: model.binding("enabled"))
                Toggle("Open at login", isOn: model.opensAtLogin)
                Picker("Speed", selection: model.string("speed")) {
                    ForEach(Speed.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                preview
                    .frame(height: 132)
                    .frame(maxWidth: .infinity)
                gesture(.slide, "Slide to move", "arrow.up.and.down.and.arrow.left.and.right", .blue) {
                    Text("Always").foregroundStyle(.secondary)
                }
                gesture(.pinch, "Pinch to resize", "arrow.up.left.and.arrow.down.right", .green) {
                    Toggle("", isOn: model.binding("pinchToResize")).labelsHidden().toggleStyle(.switch)
                }
                gesture(.tap, "Tap to maximize", "arrow.up.backward.and.arrow.down.forward.rectangle", .purple) {
                    Toggle("", isOn: model.binding("tapToMaximize")).labelsHidden().toggleStyle(.switch)
                }
                gesture(.flick, "Flick to switch desktops", "rectangle.on.rectangle.angled", .teal) {
                    Toggle("", isOn: model.binding("swipeToSwitch")).labelsHidden().toggleStyle(.switch)
                }
                gesture(.flickUp, "Flick up for Mission Control", "rectangle.3.group", .indigo) {
                    Toggle("", isOn: model.binding("verticalFlicks")).labelsHidden().toggleStyle(.switch)
                }
            } header: {
                Text("Gestures")
            } footer: {
                Text("Four fingers, on the window under the pointer. Point at a gesture to see it.")
            }

            Section("Windows") {
                Picker("Snap grid", selection: model.string("snapGrid")) {
                    ForEach(GridChoice.titled, id: \.raw) { Text($0.title).tag($0.raw) }
                }
                Toggle("Edge resistance", isOn: model.binding("edgeResistance"))
                Toggle("Animate snapping", isOn: model.binding("animateSnapping"))
            }

            Section {
                state("Accessibility", ok: model.status.accessibilityGranted,
                      okText: "Allowed", fix: "Allow…", action: model.actions.openSetup)
                gestureState
                if model.bool("swipeToSwitch") {
                    state("Desktop switching shortcuts", ok: model.status.desktopShortcutsOn,
                          okText: "On", fix: "Turn On…", action: model.actions.openKeyboardShortcuts)
                }
                if model.bool("verticalFlicks") {
                    state("Mission Control shortcuts", ok: model.status.missionControlShortcutsOn,
                          okText: "On", fix: "Turn On…", action: model.actions.openKeyboardShortcuts)
                }
            } header: {
                Text("macOS")
            } footer: {
                if let message = model.message { Text(message) }
            }

            Section("About") {
                LabeledContent("Trackpads") {
                    HStack(spacing: 10) {
                        Text(model.status.trackpads == 0 ? "None found" : "\(model.status.trackpads) connected")
                            .foregroundStyle(.secondary)
                        Button("Rescan", action: model.actions.rescan)
                    }
                }
                LabeledContent("Version") {
                    HStack(spacing: 10) {
                        Text(Flavor.isRelease ? Flavor.version : "\(Flavor.version), development build")
                            .foregroundStyle(.secondary)
                        if let updates = model.actions.updates {
                            Button("Check for Updates…", action: updates.check)
                        }
                    }
                }
                if model.actions.updates != nil {
                    Toggle("Check for updates automatically", isOn: model.checksForUpdates)
                }
                Button("Open Setup Assistant…", action: model.actions.openSetup)
            }
        }
        .formStyle(.grouped)
    }

    /// The pointed-at gesture plays from its start; otherwise one frame of the last one stays,
    /// so an idle window draws nothing.
    @ViewBuilder private var preview: some View {
        if let hovered {
            TimelineView(.animation) { context in
                GestureStage(frame: .demo(hovered, at: context.date.timeIntervalSince(hoverStart)))
            }
        } else {
            GestureStage(frame: .demo(shown, at: shown.stillTime))
        }
    }

    private func gesture<Trailing: View>(_ demo: GestureDemo, _ title: String, _ symbol: String, _ tint: Color,
                                         @ViewBuilder trailing: () -> Trailing) -> some View {
        LabeledContent {
            trailing()
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.gradient))
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                if hovered != demo { hoverStart = Date() }
                hovered = demo
                shown = demo
            } else if hovered == demo {
                hovered = nil
            }
        }
    }

    private func state(_ title: String, ok: Bool, okText: String, fix: String, action: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            if ok {
                Label(okText, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button(fix, action: action)
            }
        }
    }

    @ViewBuilder private var gestureState: some View {
        LabeledContent {
            if model.busy {
                ProgressView().controlSize(.small)
            } else if model.status.fourFingerGesturesOn {
                Button("Turn Off", action: model.turnOffGestures)
            } else {
                HStack(spacing: 10) {
                    Label("Off", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    if model.status.gesturesBackupExists {
                        Button("Restore", action: model.restoreGestures)
                    }
                }
            }
        } label: {
            Text("Four-finger swipes and pinch")
            Text(model.status.fourFingerGesturesOn
                 ? "On in macOS: they fire together with Tutamak's gestures"
                 : "Off in macOS, so they leave four fingers to Tutamak")
        }
    }
}
