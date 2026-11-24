import AppKit
import ServiceManagement

struct LaunchOptions {
    var verbose = false
    var check = false
    /// Only the setup, with Accessibility reading as not allowed and settings kept in memory:
    /// the whole flow can be tried on a Mac that is already set up, changing nothing.
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
    private let menuBarHint = MenuBarHint()

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
            scrollBlocker.start()
            runCheck()
            return
        }
        // The setup asks for the permission itself, beside System Settings, so the system's own
        // prompt is not raised on top of it.
        if !defaults.bool(forKey: "setupShown") || !AXIsProcessTrusted() {
            openSetup()
        }
        startScrollBlocker()
    }

    /// The event tap cannot be created without Accessibility permission; retry until it is granted.
    private func startScrollBlocker() {
        if scrollBlocker.start() { return }
        blockerRetry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            if self.scrollBlocker.start() {
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

    /// The choices in the Snap Grid menu.
    private static let gridChoices: [(title: String, choice: GridChoice)] = [
        ("Off", .off),
        ("Auto (by Display Width)", .auto),
        ("Halves & Quarters · 2 × 2", .fixed(GridLayout(columns: 2, rows: 2))),
        ("Thirds & Sixths · 3 × 2", .fixed(GridLayout(columns: 3, rows: 2))),
        ("Thirds · 3 × 1", .fixed(GridLayout(columns: 3, rows: 1))),
    ]

    private func applySettings() {
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
            threeFinger: SystemGestures.threeFinger
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

    /// The Mac's state as read, except Accessibility; turning gestures off and every setting
    /// stay in memory.
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
        let image = NSImage(systemSymbolName: "hand.raised.fingers.spread", accessibilityDescription: "Tutamak")
            ?? NSImage(systemSymbolName: "hand.draw", accessibilityDescription: "Tutamak")
        image?.isTemplate = true
        item.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// The menu stays short: one status line when all is well (problems are listed only when there
    /// are any, each leading to its fix), the gestures in their own submenu, then the settings.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let problems = statusProblems()
        if problems.isEmpty {
            info(menu, enabled ? "Ready · \(deviceCount) trackpad\(deviceCount == 1 ? "" : "s")" : "Paused")
        } else {
            for (title, action) in problems {
                if let action { add(menu, "⚠︎ " + title, action) } else { info(menu, "⚠︎ " + title) }
            }
        }

        menu.addItem(.separator())
        add(menu, "Enabled", #selector(toggleEnabled)).state = enabled ? .on : .off

        let gestures = NSMenu()
        info(gestures, "With four fingers:")
        let slide = NSMenuItem(title: "Slide to Move", action: nil, keyEquivalent: "")
        slide.state = .on
        slide.isEnabled = false
        gestures.addItem(slide)
        add(gestures, "Pinch to Resize", #selector(togglePinchToResize)).state = pinchToResize ? .on : .off
        add(gestures, "Tap to Maximize", #selector(toggleTapToMaximize)).state = tapToMaximize ? .on : .off
        add(gestures, "Flick to Switch Desktops", #selector(toggleSwipeToSwitch)).state = swipeToSwitch ? .on : .off
        add(gestures, "Flick Up/Down for Mission Control", #selector(toggleVerticalFlicks)).state =
            verticalFlicks ? .on : .off
        submenu(menu, "Gestures", gestures)

        let speeds = NSMenu()
        for s in Speed.allCases {
            let item = add(speeds, s.title, #selector(selectSpeed(_:)))
            item.representedObject = s.rawValue
            item.state = s == speed ? .on : .off
        }
        submenu(menu, "Speed", speeds)

        let grids = NSMenu()
        for (title, choice) in Self.gridChoices {
            let item = add(grids, title, #selector(selectGrid(_:)))
            item.representedObject = choice.raw
            item.state = choice == snapGrid ? .on : .off
        }
        grids.addItem(.separator())
        info(grids, "Drag a window over the grid and let go to")
        info(grids, "drop it into a zone; hold ⌥ to place it freely.")
        submenu(menu, "Snap Grid", grids)
        add(menu, "Edge Resistance", #selector(toggleEdgeResistance)).state = edgeResistance ? .on : .off
        add(menu, "Animate Snapping", #selector(toggleAnimateSnapping)).state = animateSnapping ? .on : .off

        menu.addItem(.separator())
        add(menu, "Launch at Login", #selector(toggleLaunchAtLogin)).state =
            SMAppService.mainApp.status == .enabled ? .on : .off
        add(menu, "Rescan Trackpads", #selector(rescanAction))
        add(menu, "Setup Assistant…", #selector(openSetupAction))
        if !SystemGestures.fourFingerEnabled, SystemGestures.hasBackup {
            add(menu, "Restore macOS Four-Finger Gestures", #selector(restoreSystemGestures))
        }
        add(menu, "Quit Tutamak", #selector(quit), key: "q")
    }

    /// What stands in the way of the gestures working, each with the action that fixes it (if any).
    private func statusProblems() -> [(String, Selector?)] {
        var problems: [(String, Selector?)] = []
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

    private func submenu(_ menu: NSMenu, _ title: String, _ submenu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
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

    @objc private func toggleEnabled() {
        defaults.set(!enabled, forKey: "enabled")
        applySettings()
    }

    @objc private func toggleEdgeResistance() {
        defaults.set(!edgeResistance, forKey: "edgeResistance")
        applySettings()
    }

    @objc private func toggleAnimateSnapping() {
        defaults.set(!animateSnapping, forKey: "animateSnapping")
        applySettings()
    }

    @objc private func toggleSwipeToSwitch() {
        defaults.set(!swipeToSwitch, forKey: "swipeToSwitch")
        applySettings()
    }

    @objc private func toggleVerticalFlicks() {
        defaults.set(!verticalFlicks, forKey: "verticalFlicks")
        applySettings()
    }

    @objc private func togglePinchToResize() {
        defaults.set(!pinchToResize, forKey: "pinchToResize")
        applySettings()
    }

    @objc private func toggleTapToMaximize() {
        defaults.set(!tapToMaximize, forKey: "tapToMaximize")
        applySettings()
    }

    @objc private func openKeyboardShortcuts() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func selectGrid(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        defaults.set(raw, forKey: "snapGrid")
        applySettings()
    }

    @objc private func selectSpeed(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        defaults.set(raw, forKey: "speed")
        applySettings()
    }

    @objc private func toggleLaunchAtLogin() {
        setLaunchAtLogin(SMAppService.mainApp.status != .enabled)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            alert("Could not change Launch at Login", error.localizedDescription)
        }
    }

    @objc private func rescanAction() {
        rescan()
    }

    @objc private func disableSystemGestures() {
        let confirm = NSAlert()
        confirm.messageText = "Turn off macOS four-finger gestures?"
        confirm.informativeText = """
        Four-finger Mission Control, switching between Spaces, and the Launchpad/desktop pinch are turned off; \
        three-finger gestures stay as they are. The current values are backed up and can be restored from this menu.

        Tutamak's own flicks can stand in: sideways switches desktops, and with Gestures > Flick Up/Down \
        for Mission Control on, up opens Mission Control and down App Exposé.
        """
        confirm.addButton(withTitle: "Turn Off")
        confirm.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        let result = SystemGestures.run("off")
        alert(result.ok ? "Turned off" : "Could not turn off", result.output)
    }

    @objc private func restoreSystemGestures() {
        let result = SystemGestures.run("restore")
        alert(result.ok ? "Restored" : "Could not restore", result.output)
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
                print("window under cursor: \(w.appName) (\(Int(w.frame.minX)),\(Int(w.frame.minY)) \(Int(w.frame.width))×\(Int(w.frame.height)))")
            } else {
                print("window under cursor: none (or not movable)")
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
// `--flick left|right|up|down`: posts what a flick of the fingers that way posts, once, and exits,
// to test the shortcut in isolation. `left` brings in the desktop on the right, as the flick does.
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
