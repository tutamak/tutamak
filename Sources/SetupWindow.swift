import AppKit
import Observation
import SwiftUI

/// What the setup reads and changes. The app delegate wires up the real ones; captures pass fakes,
/// so no state of the Mac has to be changed to draw a step.
struct SetupActions {
    var readStatus: () -> SetupStatus
    /// `--setup-demo`: Accessibility reads as not allowed, and a finished drop of the icon counts
    /// as the grant, so the whole flow can be tried on a Mac that already allowed it.
    var demo = false
    var bool: (String) -> Bool = { _ in false }
    var setBool: (String, Bool) -> Void = { _, _ in }
    var string: (String) -> String = { _ in "" }
    var setString: (String, String) -> Void = { _, _ in }
    var opensAtLogin: () -> Bool = { false }
    var setOpensAtLogin: (Bool) -> Void = { _ in }
    /// Starts (a feed) or ends (nil) the gesture practice; see `GestureController.practice`.
    var setPractice: (PracticeFeed?) -> Void = { _ in }
    /// Shows or hides the bubble under Tutamak's menu bar icon.
    var menuBarHint: (Bool) -> Void = { _ in }
    /// Turns macOS's four-finger gestures off (backing them up first); runs off the main thread.
    var turnOffSystemGestures: () -> (ok: Bool, output: String) = { (true, "") }
    /// Called after the setup changes a setting in the defaults.
    var settingsChanged: () -> Void = {}
}

/// The setup's state. Every step draws from `status`, read again while the window is open, so
/// running the setup a second time shows what is already done; opening it changes nothing.
@Observable
final class SetupModel {
    private(set) var step: SetupStep = .permission
    private(set) var status: SetupStatus
    /// A primary action that takes a moment (turning gestures off) is running.
    private(set) var busy = false
    /// What went wrong with the last action, shown under the step.
    private(set) var failure: String?
    /// The card beside System Settings is showing.
    private(set) var guiding = false
    /// Where the footer's primary button is, in the hosting view (y down), so the card can fly
    /// out of it.
    @ObservationIgnored var primaryButtonFrame: CGRect?
    @ObservationIgnored var onAllowAccess: () -> Void = {}
    @ObservationIgnored var onLeaveStep: () -> Void = {}
    @ObservationIgnored private var demoGranted = false
    /// Bumped when the setup changes a setting, so the views read it again.
    private(set) var settingsVersion = 0
    /// The practice's fingers and window, read by the drawing on each frame.
    @ObservationIgnored let feed = PracticeFeed()
    /// The gestures tried in the practice.
    private(set) var practiced: Set<GestureDemo> = []
    /// The window is open, so the current step's bubble may be showing.
    @ObservationIgnored private var open = false
    /// The window is the key window: only then may the practice run. Left on behind other
    /// windows, it would quietly turn off every gesture on the Mac.
    @ObservationIgnored private var focused = false
    /// Holds every animation at this moment (seconds), for captures; nil lets them run.
    var artTime: Double?

    @ObservationIgnored let actions: SetupActions
    @ObservationIgnored var onClose: () -> Void = {}

    init(actions: SetupActions) {
        self.actions = actions
        status = actions.readStatus()
        feed.onGesture = { [weak self] demo in self?.practiced.insert(demo) }
    }

    // MARK: What a step starts

    /// The window opened: the step's bubble comes out.
    func appeared() {
        open = true
        enter(step)
    }

    /// The window is closing: nothing of the setup may stay on, least of all the practice, which
    /// would leave every gesture doing nothing.
    func disappeared() {
        open = false
        focused = false
        leave(step)
    }

    /// The window became key, or stopped being key (another app in front, minimized, closing).
    func focusChanged(_ key: Bool) {
        guard key != focused else { return }
        focused = key
        guard step == .practice else { return }
        if key, open {
            actions.setPractice(feed)
        } else {
            actions.setPractice(nil)
        }
    }

    private func enter(_ step: SetupStep) {
        guard open else { return }
        switch step {
        case .practice:
            feed.reset()
            if focused { actions.setPractice(feed) }
        case .done:
            actions.menuBarHint(true)
        default:
            break
        }
    }

    private func leave(_ step: SetupStep) {
        switch step {
        case .practice: actions.setPractice(nil)
        case .done: actions.menuBarHint(false)
        default: break
        }
    }

    var primary: SetupPrimary { status.primary(on: step) }
    var showsSkip: Bool { status.showsSkip(on: step) }
    var showsBack: Bool { step.previous != nil }

    func refresh() {
        var fresh = actions.readStatus()
        if demoGranted { fresh.accessibilityGranted = true }
        if fresh != status { status = fresh }
    }

    func go(to target: SetupStep) {
        guard target != step else { return }
        onLeaveStep()
        leave(step)
        guiding = false
        failure = nil
        step = target
        refresh()
        enter(target)
    }

    func guideStarted() { guiding = true }

    func guideEnded(granted: Bool) {
        guiding = false
        if granted, actions.demo { demoGranted = true }
        refresh()
    }

    // MARK: Settings

    func bool(_ key: String) -> Bool {
        _ = settingsVersion
        return actions.bool(key)
    }

    func setBool(_ key: String, _ value: Bool) {
        actions.setBool(key, value)
        actions.settingsChanged()
        settingsVersion += 1
    }

    func string(_ key: String) -> String {
        _ = settingsVersion
        return actions.string(key)
    }

    func setString(_ key: String, _ value: String) {
        actions.setString(key, value)
        actions.settingsChanged()
        settingsVersion += 1
    }

    var opensAtLogin: Bool {
        _ = settingsVersion
        return actions.opensAtLogin()
    }

    func setOpensAtLogin(_ on: Bool) {
        actions.setOpensAtLogin(on)
        settingsVersion += 1
    }

    func runPrimary() {
        guard !busy else { return }
        switch primary {
        case .allowAccess:
            onAllowAccess()
        case .turnOffGestures:
            busy = true
            failure = nil
            let turnOff = actions.turnOffSystemGestures
            DispatchQueue.global(qos: .userInitiated).async {
                let result = turnOff()
                DispatchQueue.main.async {
                    self.busy = false
                    self.failure = result.ok ? nil : result.output
                    self.refresh()
                }
            }
        case .next:
            if let next = step.next { go(to: next) }
        case .finish:
            onClose()
        }
    }

    func skip() {
        if let next = step.next { go(to: next) }
    }

    func back() {
        if let previous = step.previous { go(to: previous) }
    }
}

/// The setup's window: one instance, brought forward when opened again; the app has a Dock icon
/// while it is open (`AppWindows`).
final class SetupWindowController: NSObject, NSWindowDelegate {
    static let size = CGSize(width: 460, height: 590)

    let model: SetupModel
    private var window: NSWindow?
    private var poll: Timer?
    private var guide: PermissionGuide?
    var onClose: () -> Void = {}

    init(model: SetupModel) {
        self.model = model
        super.init()
        model.onClose = { [weak self] in self?.window?.close() }
        model.onAllowAccess = { [weak self] in self?.startGuide() }
        model.onLeaveStep = { [weak self] in self?.stopGuide() }
    }

    // MARK: Permission guide

    private func startGuide() {
        stopGuide()
        let actions = model.actions
        let guide = PermissionGuide(
            demo: actions.demo,
            isGranted: { actions.readStatus().accessibilityGranted },
            onEnd: { [weak self] end in
                guard let self else { return }
                self.guide = nil
                self.model.guideEnded(granted: end == .granted)
                // Back to the setup, which now says it is allowed.
                if end == .granted, let window = self.window {
                    NSApp.activate()
                    window.makeKeyAndOrderFront(nil)
                }
            }
        )
        self.guide = guide
        model.guideStarted()
        guide.start(from: primaryButtonOnScreen())
    }

    private func stopGuide() {
        guide?.cancel()
        guide = nil
    }

    private func primaryButtonOnScreen() -> CGRect? {
        guard let window, let host = window.contentView, let f = model.primaryButtonFrame else { return nil }
        let inHost = NSRect(x: f.minX, y: host.bounds.height - f.maxY, width: f.width, height: f.height)
        return window.convertToScreen(host.convert(inHost, to: nil))
    }

    var isOpen: Bool { window != nil }
    var windowNumber: Int? { window?.windowNumber }

    func show(appearance: NSAppearance? = nil) {
        if self.window == nil { AppWindows.opened() }
        let window = self.window ?? makeWindow()
        self.window = window
        if let appearance { window.appearance = appearance }
        model.refresh()
        model.appeared()
        startPolling()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Tutamak Setup"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        let host = NSHostingView(rootView: SetupView(model: model))
        // The window keeps its size; the content fills it rather than resizing it.
        host.sizingOptions = []
        window.contentView = host
        window.setFrame(NSRect(origin: .zero, size: Self.size), display: false)
        window.center()
        return window
    }

    /// Permission and gesture settings change in System Settings, outside the app: look again
    /// every second while the window is open.
    private func startPolling() {
        guard poll == nil, model.artTime == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.model.refresh() }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.focusChanged(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        model.focusChanged(false)
    }

    func windowWillClose(_ notification: Notification) {
        stopGuide()
        model.disappeared()
        poll?.invalidate()
        poll = nil
        // Drop the SwiftUI content so nothing in it keeps drawing.
        window?.contentView = nil
        window = nil
        AppWindows.closed()
        onClose()
    }
}
