import AppKit
import ServiceManagement

struct LaunchOptions {
    var verbose = false
    var check = false
    /// Runs only the setup, with Accessibility reported as not allowed and settings kept in memory,
    /// so the whole flow can be tried on a Mac that is already set up without changing anything.
    var setupDemo = false

    init(_ arguments: [String]) {
        verbose = arguments.contains("--debug")
        check = arguments.contains("--check")
        setupDemo = arguments.contains("--setup-demo")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let options: LaunchOptions
    private let controller: GestureController
    private let scrollBlocker: ScrollBlocker
    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem?
    private var deviceCount = 0
    private var blockerRetry: Timer?
    private var pendingRescan: DispatchWorkItem?
    private var setup: SetupWindowController?
    private var settingsWindow: SettingsWindowController?
    private var aboutWindow: AboutWindowController?
    private var iconRefresh: Timer?
    private var iconAlert: Bool?
    private let menuBarHint = MenuBarHint()
    /// Nil in a development build, which has no update feed.
    private var updater: Updater?

    init(options: LaunchOptions) {
        self.options = options
        let blocker = ScrollBlocker()
        scrollBlocker = blocker
        controller = GestureController(verbose: options.verbose, scrollBlocker: blocker)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [
            "enabled": true,
            "speed": Speed.normal.rawValue,
            "edgeResistance": true,
            "swipeToSwitch": true,
            "verticalFlicks": false,
            "pinchToResize": true,
            "tapToMaximize": true,
            "animateSnapping": true,
            "snapGrid": "off",
        ])
        applySettings()

        if options.setupDemo {
            openSetup(demo: true)
            return
        }
        if !options.check, AppMover.offerMoveIfNeeded() { return }

        let controller = self.controller
        Multitouch.shared.onFrame = { device, touches, time in
            controller.handle(device: device, touches: touches, time: time)
        }
        rescan()

        Multitouch.shared.observeDevices { [weak self] in
            self?.scheduleRescan("trackpad added or removed")
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        setupStatusItem()

        if options.check {
            if AXIsProcessTrusted() { scrollBlocker.start() }
            runCheck()
            return
        }
        if let feed = Flavor.feed(info: Bundle.main.infoDictionary ?? [:], environment: ProcessInfo.processInfo.environment) {
            let updater = Updater(feed: feed)
            updater.onChange = { [weak self] in self?.refreshStatusIcon() }
            self.updater = updater
        }
        // The setup asks for the permission itself, beside System Settings, so the system's own
        // prompt is not raised on top of it.
        if !defaults.bool(forKey: "setupShown") || !AXIsProcessTrusted() {
            openSetup()
        }
        startScrollBlocker()
    }

    /// The event tap needs Accessibility permission; it is started once the permission is there.
    /// Never tried before: creating it without the permission makes macOS raise its own prompt, on
    /// top of the setup that is about to ask for the same thing beside System Settings.
    private func startScrollBlocker() {
        if AXIsProcessTrusted(), scrollBlocker.start() { return }
        blockerRetry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            if AXIsProcessTrusted(), self.scrollBlocker.start() {
                timer.invalidate()
                self.blockerRetry = nil
            }
        }
    }

    // MARK: Settings

    private var enabled: Bool { defaults.bool(forKey: "enabled") }
    private var speed: Speed { Speed(rawValue: defaults.string(forKey: "speed") ?? "") ?? .normal }
    private var edgeResistance: Bool { defaults.bool(forKey: "edgeResistance") }
    private var swipeToSwitch: Bool { defaults.bool(forKey: "swipeToSwitch") }
    private var verticalFlicks: Bool { defaults.bool(forKey: "verticalFlicks") }
    private var pinchToResize: Bool { defaults.bool(forKey: "pinchToResize") }
    private var tapToMaximize: Bool { defaults.bool(forKey: "tapToMaximize") }
    private var animateSnapping: Bool { defaults.bool(forKey: "animateSnapping") }
    private var snapGrid: GridChoice { GridChoice(defaults.string(forKey: "snapGrid") ?? "off") }

    private func applySettings() {
        refreshStatusIcon()
        controller.update(.init(
            enabled: enabled,
            pointsPerUnit: speed.pointsPerUnit,
            edgeResistance: edgeResistance,
            animateSnapping: animateSnapping,
            swipeToSwitch: swipeToSwitch,
            verticalFlicks: verticalFlicks,
            pinchToResize: pinchToResize,
            tapToMaximize: tapToMaximize,
            grid: snapGrid
        ))
    }

    private func rescan() {
        controller.reset()
        deviceCount = Multitouch.shared.start()
        logger.info("started \(self.deviceCount) trackpad(s)")
    }

    @objc private func didWake() {
        // Devices send no frames after sleep unless they are restarted.
        scheduleRescan("woke from sleep")
    }

    @objc private func screensChanged() {
        // Plugging in a display or closing the lid (clamshell mode) can switch trackpads on and off.
        scheduleRescan("display configuration changed")
    }

    /// Restarts the trackpads once things settle; a burst of changes leads to a single rescan.
    private func scheduleRescan(_ reason: String) {
        pendingRescan?.cancel()
        let item = DispatchWorkItem { [weak self] in
            logger.info("rescanning trackpads: \(reason, privacy: .public)")
            self?.rescan()
        }
        pendingRescan = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }

    // MARK: Setup

    /// One setup window; opening it again brings it forward.
    private func openSetup(demo: Bool = false) {
        if setup == nil {
            let controller = SetupWindowController(model: SetupModel(actions: demo ? demoSetupActions() : setupActions()))
            controller.onClose = { [weak self] in
                self?.setup = nil
                if demo { NSApp.terminate(nil) }
            }
            setup = controller
        }
        if !demo { defaults.set(true, forKey: "setupShown") }
        setup?.show()
    }

    private func setupStatus() -> SetupStatus {
        SetupStatus(
            accessibilityGranted: AXIsProcessTrusted(),
            fourFingerGesturesOn: SystemGestures.fourFingerEnabled,
            trackpads: deviceCount,
            desktopShortcutsOn: SystemShortcut.desktopSwitching.allSatisfy(\.isEnabled),
            missionControlShortcutsOn: SystemShortcut.missionControlAndAppWindows.allSatisfy(\.isEnabled),
            threeFinger: SystemGestures.threeFinger,
            gesturesBackupExists: SystemGestures.hasBackup
        )
    }

    private func setupActions() -> SetupActions {
        let defaults = self.defaults
        var actions = SetupActions(readStatus: { [weak self] in self?.setupStatus() ?? SetupStatus() })
        actions.turnOffSystemGestures = { SystemGestures.run("off") }
        actions.bool = { defaults.bool(forKey: $0) }
        actions.setBool = { defaults.set($1, forKey: $0) }
        actions.string = { defaults.string(forKey: $0) ?? "" }
        actions.setString = { defaults.set($1, forKey: $0) }
        actions.settingsChanged = { [weak self] in self?.applySettings() }
        actions.opensAtLogin = { SMAppService.mainApp.status == .enabled }
        actions.setOpensAtLogin = { [weak self] on in self?.setLaunchAtLogin(on) }
        let controller = self.controller
        actions.setPractice = { controller.practice($0) }
        actions.menuBarHint = { [weak self] on in self?.showMenuBarHint(on) }
        return actions
    }

    /// The bubble under the menu bar icon, if the icon is on screen (a crowded menu bar can hide it).
    private func showMenuBarHint(_ on: Bool) {
        guard on else { return menuBarHint.hide() }
        guard let frame = statusItem?.button?.window?.frame, frame.width > 0,
              NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else { return }
        menuBarHint.show(below: frame)
    }

    /// The Mac's real state, except that Accessibility reads as not granted. Turning gestures off
    /// changes nothing, and every setting stays in memory.
    private func demoSetupActions() -> SetupActions {
        var store: [String: Any] = defaults.dictionaryRepresentation()
        var actions = SetupActions(readStatus: { [weak self] in
            var status = self?.setupStatus() ?? SetupStatus()
            status.accessibilityGranted = false
            return status
        })
        actions.demo = true
        actions.turnOffSystemGestures = { (true, "Demo: nothing was changed.") }
        actions.bool = { (store[$0] as? Bool) ?? false }
        actions.setBool = { store[$0] = $1 }
        actions.string = { (store[$0] as? String) ?? "" }
        actions.setString = { store[$0] = $1 }
        var opensAtLogin = SMAppService.mainApp.status == .enabled
        actions.opensAtLogin = { opensAtLogin }
        actions.setOpensAtLogin = { opensAtLogin = $0 }
        return actions
    }

    // MARK: Menu

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        refreshStatusIcon()
        // Granting the permission or turning macOS's gestures off elsewhere changes the icon's dot.
        iconRefresh = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshStatusIcon()
        }
    }

    /// The icon shows a dot while something needs attention or an update is waiting, and is dimmed
    /// while paused.
    private func refreshStatusIcon() {
        guard let button = statusItem?.button else { return }
        let alert = !statusProblems().isEmpty || updater?.waiting != nil
        if alert != iconAlert {
            button.image = MenuBarIcon.image(alert: alert)
            iconAlert = alert
        }
        button.appearsDisabled = !enabled
    }

    /// The menu stays short: one status line when all is well (problems are listed only when there
    /// are any, each leading to its fix), Enabled, the items that open the settings and the setup,
    /// and About beside the update check.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let version = updater?.waiting {
            add(menu, "Update Available: Tutamak \(version)…", #selector(checkForUpdates))
        }
        let problems = statusProblems()
        if problems.isEmpty {
            let flavor = Flavor.isRelease ? "" : "Dev build · "
            info(menu, flavor + (enabled ? "Ready · \(deviceCount) trackpad\(deviceCount == 1 ? "" : "s")" : "Paused"))
        } else {
            for (title, action) in problems {
                if let action { add(menu, "⚠︎ " + title, action) } else { info(menu, "⚠︎ " + title) }
            }
        }

        menu.addItem(.separator())
        add(menu, "Enabled", #selector(toggleEnabled)).state = enabled ? .on : .off
        add(menu, "Settings…", #selector(openSettingsAction), key: ",")
        add(menu, "Setup Assistant…", #selector(openSetupAction))
        menu.addItem(.separator())
        add(menu, "About \(Flavor.name)", #selector(openAboutAction))
        if updater != nil, updater?.waiting == nil {
            add(menu, "Check for Updates…", #selector(checkForUpdates))
        }
        menu.addItem(.separator())
        add(menu, "Quit \(Flavor.name)", #selector(quit), key: "q")
    }

    /// What stands in the way of the gestures working, each with the action that fixes it (if any).
    private func statusProblems() -> [(String, Selector?)] {
        var problems: [(String, Selector?)] = []
        if let other = Flavor.othersRunning().first {
            // Both copies would move the window under the same four fingers.
            problems.append(("Quit \(other.localizedName ?? "the Other Tutamak") (Also Running)", #selector(quitOtherFlavor)))
        }
        if !AXIsProcessTrusted() {
            problems.append(("Grant Accessibility Permission…", #selector(openAccessibility)))
        } else if !scrollBlocker.isRunning {
            problems.append(("Scroll blocker could not start", nil))
        }
        if deviceCount == 0 {
            problems.append(("No trackpad found", nil))
        }
        if SystemGestures.fourFingerEnabled {
            problems.append(("Turn Off macOS Four-Finger Gestures…", #selector(disableSystemGestures)))
        }
        if swipeToSwitch, !SystemShortcut.desktopSwitching.allSatisfy(\.isEnabled) {
            problems.append(("Turn On Desktop Switching Shortcuts…", #selector(openKeyboardShortcuts)))
        }
        if verticalFlicks, !SystemShortcut.missionControlAndAppWindows.allSatisfy(\.isEnabled) {
            problems.append(("Turn On Mission Control Shortcuts…", #selector(openKeyboardShortcuts)))
        }
        return problems
    }


    private func info(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    // MARK: Menu actions

    @objc private func openAccessibility() {
        openSetup()
    }

    @objc private func openSetupAction() {
        openSetup()
    }

    @objc private func openSettingsAction() {
        openSettings()
    }

    /// One settings window; opening it again brings it forward.
    private func openSettings() {
        if settingsWindow == nil {
            let defaults = self.defaults
            let controller = SettingsWindowController(model: SettingsModel(actions: SettingsActions(
                status: { [weak self] in self?.setupStatus() ?? SetupStatus() },
                bool: { defaults.bool(forKey: $0) },
                setBool: { defaults.set($1, forKey: $0) },
                string: { defaults.string(forKey: $0) ?? "" },
                setString: { defaults.set($1, forKey: $0) },
                opensAtLogin: { SMAppService.mainApp.status == .enabled },
                setOpensAtLogin: { [weak self] in self?.setLaunchAtLogin($0) },
                settingsChanged: { [weak self] in self?.applySettings() },
                turnOffGestures: { SystemGestures.run("off") },
                restoreGestures: { SystemGestures.run("restore") },
                openSetup: { [weak self] in self?.openSetup() },
                openKeyboardShortcuts: { [weak self] in self?.openKeyboardShortcuts() },
                rescan: { [weak self] in self?.rescan() },
                updates: updater.map { updater in
                    UpdateActions(check: { updater.check() },
                                  checksAutomatically: { updater.checksAutomatically },
                                  setChecksAutomatically: { updater.checksAutomatically = $0 })
                }
            )))
            controller.onClose = { [weak self] in self?.settingsWindow = nil }
            settingsWindow = controller
        }
        settingsWindow?.show()
    }

    /// One About window; opening it again brings it forward.
    @objc private func openAboutAction() {
        if aboutWindow == nil {
            let controller = AboutWindowController()
            controller.onClose = { [weak self] in self?.aboutWindow = nil }
            aboutWindow = controller
        }
        aboutWindow?.show()
    }

    @objc private func checkForUpdates() {
        updater?.check()
    }

    @objc private func quitOtherFlavor() {
        for app in Flavor.othersRunning() { app.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshStatusIcon() }
    }

    @objc private func toggleEnabled() {
        defaults.set(!enabled, forKey: "enabled")
        applySettings()
    }

    @objc private func openKeyboardShortcuts() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            alert("Could not change \"Open at login\"", error.localizedDescription)
        }
    }

    @objc private func rescanAction() {
        rescan()
    }

    @objc private func disableSystemGestures() {
        let confirm = NSAlert()
        confirm.messageText = "Turn off macOS four-finger gestures?"
        confirm.informativeText = """
        This turns off the four-finger swipes for Mission Control and for switching desktops, and the \
        Launchpad and Show Desktop pinch; three-finger gestures stay as they are. The current values are backed up \
        and can be restored in Settings > macOS.

        Tutamak's own flicks can stand in: a sideways flick switches desktops, and with Settings > Gestures > \
        Flick up for Mission Control on, a flick up opens Mission Control and a flick down opens App Exposé.
        """
        confirm.addButton(withTitle: "Turn Off")
        confirm.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        let result = SystemGestures.run("off")
        alert(result.ok ? "Turned off" : "Could not turn off", result.output)
    }


    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate()
        alert.runModal()
    }

    // MARK: --check

    /// Starts up without asking for permission, prints the status and quits.
    private func runCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            print("trackpads: \(self.deviceCount)")
            print("accessibility permission: \(AXIsProcessTrusted() ? "granted" : "missing")")
            print("macOS four-finger gestures: \(SystemGestures.fourFingerEnabled ? "on" : "off")")
            print("scroll blocker: \(self.scrollBlocker.isRunning ? "running" : "not started")")
            for shortcut in SystemShortcut.allCases {
                print("shortcut \(shortcut.title): \(shortcut.isEnabled ? "on" : "off")")
            }
            let cursor = CGEvent(source: nil)?.location ?? .zero
            if let w = AX.window(at: cursor) {
                print("window under pointer: \(w.appName) (\(Int(w.frame.minX)),\(Int(w.frame.minY)) \(Int(w.frame.width))×\(Int(w.frame.height)))")
            } else {
                print("window under pointer: none (or not movable)")
            }
            if let menu = self.statusItem?.menu {
                self.menuNeedsUpdate(menu)
                for item in [menu.items, menu.items.compactMap(\.submenu).flatMap(\.items)] {
                    print("menu: " + item.map { i in
                        i.isSeparatorItem ? "—" : (i.state == .on ? "✓ " : "") + i.title
                    }.joined(separator: " | "))
                }
            }
            NSApp.terminate(nil)
        }
    }
}

let arguments = CommandLine.arguments
if arguments.contains("--touches") {
    TouchLog.run()
}
// `--flick left|right|up|down`: posts, once, what a flick in that direction posts, then exits, to
// test the shortcut in isolation. `left` brings in the desktop on the right, as the flick does.
if let i = arguments.firstIndex(of: "--flick") {
    let directions: [String: SwipeDirection] = ["left": .left, "right": .right, "up": .up, "down": .down]
    guard let name = arguments.dropFirst(i + 1).first, let direction = directions[name] else {
        print("usage: Tutamak --flick left|right|up|down")
        exit(2)
    }
    let shortcut = SystemShortcut(flick: direction)
    let posted = shortcut.post()
    print(posted ? "posted: \(shortcut.title)" : "\"\(shortcut.title)\" is turned off in Keyboard Shortcuts")
    // The window server checks the poster's permission after `post` returns; a process that has
    // already exited by then loses the event (most runs did). The running app never exits that soon.
    Thread.sleep(forTimeInterval: 0.5)
    exit(posted ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate(options: LaunchOptions(arguments))
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
