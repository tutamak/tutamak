import AppKit
import ApplicationServices
import os

let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "local.tutamak", category: "gestures")

/// Takes touch frames and turns the four-finger gestures into window actions:
/// slide to move the window under the pointer, pinch to resize it, tap to maximize or restore it,
/// flick sideways to switch desktops (and, if on, up or down for Mission Control or App Exposé).
///
/// All state lives on `queue`; the trackpad threads only drop frames there. Window motion itself
/// is paced to the display by `WindowAnimator` on the main thread.
final class GestureController {
    struct Settings {
        var enabled = true
        /// How far the pointer travels (pt) when the fingers slide across the full trackpad width.
        var pointsPerUnit: CGFloat = 2000
        /// Whether window edges stick to display edges.
        var edgeResistance = true
        /// Whether snapping, maximizing and restoring animate.
        var animateSnapping = true
        var swipeToSwitch = true
        /// Flick up for Mission Control, down for App Exposé.
        var verticalFlicks = false
        var pinchToResize = true
        var tapToMaximize = true
        /// The snap grid that windows can be dropped into while dragging, if any.
        var grid = GridChoice.off
    }

    /// Approximate trackpad aspect ratio (height / width): built-in ≈0.62, Magic Trackpad ≈0.72.
    private let trackpadAspect: CGFloat = 0.66
    /// Finger travel needed to push past an edge, as a fraction of the trackpad width (≈4 mm).
    /// Converted to points here so the same finger distance is felt at every speed setting.
    private let resistanceTravel: CGFloat = 0.025
    /// The window scales with the hand like a zoom: by (spread now / spread at landing) to this power.
    /// Above 1 so the little room left to open an already-open hand still grows the window enough:
    /// opening 20% grows it ~30%, closing to half shrinks it to ~35%.
    private let resizeExponent: CGFloat = 1.5
    /// Resizing stops here (or at the window's own size, if smaller); apps may enforce more.
    private let minimumSize = CGSize(width: 240, height: 160)

    private let queue = DispatchQueue(label: "tutamak.gesture", qos: .userInteractive)
    private let animator = WindowAnimator(mover: WindowMover())
    private let overlay = SnapOverlay()
    private let gridBackdrop = GridBackdrop()
    private let scrollBlocker: ScrollBlocker
    private let verbose: Bool

    private var settings = Settings()
    private var tracker = GestureTracker()
    private var activeDevice: UnsafeMutableRawPointer?
    private var drag: DragSession?
    private var resize: ResizeSession?
    private var watchdog: DispatchWorkItem?
    /// Frames to restore with a tap, per window: the frame before maximizing, and the frame
    /// the window actually took (a window may refuse the exact screen size).
    private var restoreFrames: [AXUIElement: RestoreEntry] = [:]
    private var pendingDrop: PendingDrop?
    private var dropHold = DropHold()
    private var dropTimer: DispatchWorkItem?
    /// When a window was last released over the grid, to log how soon the next drag began.
    private var lastGridRelease: Double?
    /// The setup's practice, while it is on: gestures go there and nothing else happens.
    private var practice: PracticeFeed?

    private struct DragSession {
        let window: TargetWindow?
        let screens: [ScreenInfo]
        let grab: CGVector
        var cursor: CGPoint
        var drop: Drop?
        var target: CGRect?
        /// The visible area the grid is drawn over, if any, and the window server's ID of the
        /// dragged window, which the grid is ordered below.
        var backdrop: CGRect?
        var windowID: CGWindowID?
        /// Finger movement (trackpad units) in the last moments, to tell how fast the hand lifted.
        var recent: [(time: Double, delta: CGVector)] = []
        var moves = 0
        /// Raw and smoothed finger path (pt) since the drag began.
        var raw = CGPoint.zero
        var smoothed = CGPoint.zero
        var smoother = PointerSmoother()
        var resistance = EdgeResistance()
    }

    private struct ResizeSession {
        let window: TargetWindow
        let visible: CGRect
        /// Which edges move, from where the pointer was when the resize began.
        let grip: ResizeGrip
        let anchor: CGPoint
        /// How spread the fingers were when they landed (mean distance from their center).
        let handSpread: CGFloat
        var target: CGRect
        var spread = Spread.zero
        var updates = 0
        var smoother = PointerSmoother()
    }

    /// Where a released window goes.
    private enum Drop: Equatable {
        /// Pushed against a display edge: a half or the whole screen, at once.
        case edge(SnapZone)
        /// A zone of the grid, at once or after a wait (see `DropHold`).
        case grid(GridLayout)
    }

    /// A drop into the grid that `DropHold` has not released yet.
    private struct PendingDrop {
        let window: TargetWindow
        let from: CGRect
        let target: CGRect
        let layout: GridLayout
        /// The zone is the whole visible area: a tap afterward restores, as after maximizing.
        let fills: Bool
        let releasedAt: Double
    }

    private struct RestoreEntry {
        let before: CGRect
        var after: CGRect?
    }

    init(verbose: Bool, scrollBlocker: ScrollBlocker) {
        self.verbose = verbose
        self.scrollBlocker = scrollBlocker
    }

    func update(_ settings: Settings) {
        queue.async {
            self.settings = settings
            self.tracker.recognizesSwipes = settings.swipeToSwitch
            self.tracker.recognizesVerticalSwipes = settings.verticalFlicks
            self.tracker.recognizesPinch = settings.pinchToResize
            self.tracker.recognizesTap = settings.tapToMaximize
            if !settings.enabled { self.cancel() }
        }
        let animator = self.animator
        DispatchQueue.main.async { animator.animatesSnapping = settings.animateSnapping }
    }

    /// Starts or ends the setup's practice. While it is on, frames and gestures go to `feed` and
    /// no window moves, no shortcut is posted. The setup ends it on every way out.
    func practice(_ feed: PracticeFeed?) {
        queue.async {
            self.cancel()
            self.practice = feed
        }
    }

    /// Called when the trackpads restart: if a device that went silent stayed `activeDevice`,
    /// frames from the other trackpad would be ignored forever.
    func reset() {
        queue.async { self.cancel() }
    }

    /// Called from a trackpad thread.
    func handle(device: UnsafeMutableRawPointer, touches: [RawTouch], time: Double) {
        queue.async { self.process(device: device, touches: touches, time: time) }
    }

    // MARK: On the queue

    private func process(device: UnsafeMutableRawPointer, touches: [RawTouch], time: Double) {
        guard settings.enabled else { return }
        // Once a gesture has started on one trackpad, frames from the other one must not mix in.
        if let active = activeDevice, active != device { return }

        let points = touches.compactMap { t -> TouchPoint? in
            guard t.state == 4 else { return nil }
            return TouchPoint(id: t.id, position: CGPoint(x: CGFloat(t.x), y: CGFloat(t.y)))
        }
        let decisionBefore = tracker.lastDecision
        let events = tracker.process(points, at: time)
        activeDevice = tracker.isActive ? device : nil
        scrollBlocker.engaged = tracker.isEngaged
        if let decision = tracker.lastDecision, decision != decisionBefore { logDecision(decision) }
        if let practice {
            practice.touches(Dictionary(points.map { ($0.id, CGPoint(x: $0.position.x, y: 1 - $0.position.y)) },
                                        uniquingKeysWith: { a, _ in a }))
            for event in events { practice.handle(event) }
            return
        }
        if dropHold.isPending { updatePendingDrop(events, at: time) }

        for event in events {
            switch event {
            case .began: beginDrag(at: time)
            case .moved(let delta): moveDrag(delta, at: time)
            case .ended: endDrag(at: time)
            case .swiped(let direction): flick(direction)
            case .resizeBegan(let start): beginResize(handSpread: start, at: time)
            case .resized(let spread): updateResize(spread, at: time)
            case .resizeEnded: endResize()
            case .tapped: toggleMaximize()
            }
        }
        scheduleWatchdog()
    }

    // MARK: Drag

    private func beginDrag(at time: Double) {
        let cursor = CGEvent(source: nil)?.location ?? .zero
        let screens = DispatchQueue.main.sync { ScreenInfo.current() }
        let window = grabWindow(at: cursor, needsSize: false)
        if let window { log("drag began: \(window.appName) \(describe(window.frame))") }
        if let released = lastGridRelease, time - released < 1.5 {
            log("drag began \(Int(((time - released) * 1000).rounded())) ms after a release over the grid")
        }
        lastGridRelease = nil

        let origin = window?.frame.origin ?? cursor
        let grab = CGVector(dx: cursor.x - origin.x, dy: cursor.y - origin.y)
        var s = DragSession(window: window, screens: screens, grab: grab, cursor: cursor)
        s.windowID = window.flatMap { AX.windowID($0.element) }
        // Start the filter at zero so the first step (the travel that crossed the threshold) is smoothed too.
        _ = s.smoother.filter(.zero, at: time)
        s.resistance.strength = settings.pointsPerUnit * resistanceTravel
        drag = s

        if let window {
            let animator = self.animator
            DispatchQueue.main.async { animator.follow(window, grab: grab) }
        }
    }

    private func moveDrag(_ delta: CGVector, at time: Double) {
        guard var s = drag, let window = s.window else { return }
        let k = settings.pointsPerUnit
        s.recent.append((time, delta))
        s.recent.removeAll { $0.time < time - 0.2 }

        // 1. Convert the finger path to points (y grows upward on the trackpad, downward on screen) and smooth it.
        s.raw.x += delta.dx * k
        s.raw.y -= delta.dy * k * trackpadAspect
        let smoothed = s.smoother.filter(s.raw, at: time)
        var step = CGVector(dx: smoothed.x - s.smoothed.x, dy: smoothed.y - s.smoothed.y)
        s.smoothed = smoothed

        // 2. If a window edge reached a display edge, absorb part of the movement.
        if settings.edgeResistance {
            let frame = CGRect(
                origin: CGPoint(x: s.cursor.x - s.grab.dx, y: s.cursor.y - s.grab.dy),
                size: window.frame.size
            )
            let wasHolding = s.resistance.isHolding
            let asked = step
            step = s.resistance.apply(step, frame: frame, visibleFrames: s.screens.map(\.visible))
            if wasHolding != s.resistance.isHolding {
                log(String(format: "%@ at (%.1f, %.1f), step (%+.2f, %+.2f) became (%+.2f, %+.2f)",
                           s.resistance.isHolding ? "held at an edge" : "let go of the edge",
                           frame.minX, frame.minY, asked.dx, asked.dy, step.dx, step.dy))
            }
        }

        let displays = s.screens.map(\.frame)
        s.cursor = Geometry.clamp(
            CGPoint(x: s.cursor.x + step.dx, y: s.cursor.y + step.dy), previous: s.cursor, displays: displays
        )
        s.moves += 1

        // 3. Hand the target to the animator, which moves the window and pointer at the display's pace.
        let origin = CGPoint(x: s.cursor.x - s.grab.dx, y: s.cursor.y - s.grab.dy)
        let animator = self.animator
        DispatchQueue.main.async { animator.setTarget(origin) }

        // 4. Where the window would land if released now: a display edge first, then the grid.
        //    Holding ⌥ places it freely.
        var drop: Drop?
        var target: CGRect?
        var backdrop: (visible: CGRect, layout: GridLayout)?
        if !Self.placingFreely() {
            let screen = s.screens.first { $0.frame.contains(s.cursor) }
            let layout = screen.flatMap { settings.grid.layout(for: $0.visible) }
            if let screen, let layout { backdrop = (screen.visible, layout) }
            if let hit = Geometry.snapZone(at: s.cursor, displays: displays),
               let edgeScreen = s.screens.first(where: { $0.frame == hit.display }) {
                drop = .edge(hit.zone)
                target = Geometry.snapFrame(hit.zone, visible: edgeScreen.visible)
            } else if let backdrop {
                drop = .grid(backdrop.layout)
                target = Geometry.gridZone(at: s.cursor, in: backdrop.visible, layout: backdrop.layout)
            }
        }
        s.drop = drop
        if target != s.target {
            s.target = target
            let overlay = self.overlay
            DispatchQueue.main.async {
                if let target { overlay.show(target) } else { overlay.hide() }
            }
            if verbose { log("zone: \(target.map(describe) ?? "none")") }
        }
        if backdrop?.visible != s.backdrop {
            s.backdrop = backdrop?.visible
            let grid = gridBackdrop
            let cells = backdrop.map { Geometry.gridCells($0.layout, in: $0.visible) }
            let below = s.windowID
            DispatchQueue.main.async {
                if let backdrop, let cells { grid.show(cells, in: backdrop.visible, below: below) } else { grid.hide() }
            }
        }
        drag = s
    }

    /// Whether ⌥ is held: the window is placed exactly where it is released.
    private static func placingFreely() -> Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)
    }

    private func endDrag(at time: Double = 0) {
        guard let s = drag else { return }
        drag = nil

        let overlay = self.overlay
        let animator = self.animator
        let grid = gridBackdrop
        guard let window = s.window else {
            DispatchQueue.main.async {
                overlay.hide()
                grid.hide()
            }
            return
        }
        let free = Self.placingFreely()
        guard !free, let target = s.target, let drop = s.drop else {
            DispatchQueue.main.async {
                animator.release()
                overlay.hide()
                grid.hide()
            }
            let origin = CGPoint(x: s.cursor.x - s.grab.dx, y: s.cursor.y - s.grab.dy)
            let visible = screen(containing: CGRect(origin: origin, size: window.frame.size), in: s.screens).visible
            log(String(format: "drag released%@ at (%.1f, %.1f)%@, screen's visible area %@ (%d frames)",
                       free ? " freely (⌥)" : "", origin.x, origin.y, s.resistance.isHolding ? ", held at an edge" : "",
                       describe(visible), s.moves))
            watchAfterRelease(window, left: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()))
            return
        }
        if case .grid(let layout) = drop {
            // The grid and the preview stay up until the drop happens or is canceled.
            DispatchQueue.main.async { animator.release() }
            let released = CGRect(
                origin: CGPoint(x: s.cursor.x - s.grab.dx, y: s.cursor.y - s.grab.dy), size: window.frame.size
            )
            pendingDrop = PendingDrop(
                window: window, from: released, target: target, layout: layout,
                fills: s.screens.contains { Geometry.isClose($0.visible, target, tolerance: 1) },
                releasedAt: time
            )
            lastGridRelease = time
            let speed = liftSpeed(s, at: time)
            let action = dropHold.released(speed: speed)
            log(String(format: "released over the grid at %.2f widths/s: %@ (%d frames)",
                       speed, action == .drop ? "dropping" : "waiting for the fingers to come back", s.moves))
            apply(action)
            return
        }
        guard case .edge(let zone) = drop else { return }
        DispatchQueue.main.async { grid.hide() }

        // Snapping to the whole screen counts as maximizing: a tap afterward restores the frame from before the drag.
        var completion: ((CGRect) -> Void)?
        if zone == .maximize {
            remember(before: window.frame, for: window.element)
            completion = rememberActualFrame(of: window.element)
        }
        DispatchQueue.main.async {
            animator.snap(to: target, completion: completion)
            overlay.hide()
        }
        log("snapping: \(zone) \(describe(target)) (\(s.moves) frames)")
    }

    /// Reads the window back after a release and logs it if it is not where Tutamak left it: that
    /// is the app (or macOS) moving it afterward, not Tutamak.
    private func watchAfterRelease(_ window: TargetWindow, left: CGPoint) {
        for delay in [0.15, 0.5, 1.0] {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let frame = AX.frame(window.element) else { return }
                guard abs(frame.minX - left.x) >= 0.5 || abs(frame.minY - left.y) >= 0.5 else { return }
                self.log("\(Int(delay * 1000)) ms after release the window is at \(self.describe(frame)); Tutamak left it at (\(Int(left.x)),\(Int(left.y)))")
            }
        }
    }

    // MARK: Grid drop

    /// How fast the fingers were sliding (trackpad widths per second) in the last 0.1 s before `time`.
    private func liftSpeed(_ s: DragSession, at time: Double) -> CGFloat {
        let window = 0.1
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        for m in s.recent where m.time > time - window {
            dx += m.delta.dx
            dy += m.delta.dy
        }
        return hypot(dx, dy * trackpadAspect) / window
    }

    private func apply(_ action: DropHold.Action) {
        switch action {
        case .drop:
            performDrop()
        case .wait(let seconds):
            dropTimer?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self, let next = self.dropHold.expired() else { return }
                self.apply(next)
            }
            dropTimer = item
            queue.asyncAfter(deadline: .now() + seconds, execute: item)
        case .cancel(let keepPreview):
            log("drop canceled: grabbed again")
            cancelDrop(hidePreview: !keepPreview)
        }
    }

    private func updatePendingDrop(_ events: [GestureEvent], at time: Double) {
        let wasHeld = dropHold.isHeld
        let otherGesture = events.contains { event in
            if case .resizeBegan = event { return true }
            return false
        }
        let action = dropHold.frame(engaged: tracker.isEngaged, dragBegan: events.contains(.began), otherGesture: otherGesture)
        if !wasHeld, dropHold.isHeld, let p = pendingDrop {
            log("fingers back \(Int(((time - p.releasedAt) * 1000).rounded())) ms after release; drop held")
        }
        if let action { apply(action) }
    }

    private func performDrop() {
        guard let p = pendingDrop else { return }
        pendingDrop = nil
        dropTimer?.cancel()
        dropTimer = nil
        var completion: ((CGRect) -> Void)?
        if p.fills {
            remember(before: p.window.frame, for: p.window.element)
            completion = rememberActualFrame(of: p.window.element)
        }
        let overlay = self.overlay
        let animator = self.animator
        let grid = gridBackdrop
        DispatchQueue.main.async {
            animator.animate(p.window, from: p.from, to: p.target, label: "snapped", completion: completion)
            overlay.hide()
            grid.hide()
        }
        log("dropping into the \(p.layout) grid: \(describe(p.target))")
    }

    private func cancelDrop(hidePreview: Bool = true) {
        dropTimer?.cancel()
        dropTimer = nil
        guard pendingDrop != nil else { return }
        pendingDrop = nil
        if hidePreview {
            let overlay = self.overlay
            let grid = gridBackdrop
            DispatchQueue.main.async {
                overlay.hide()
                grid.hide()
            }
        }
    }

    // MARK: Resize

    private func beginResize(handSpread: Spread, at time: Double) {
        let cursor = CGEvent(source: nil)?.location ?? .zero
        guard let window = grabWindow(at: cursor, needsSize: true) else {
            resize = nil
            return
        }
        let screens = DispatchQueue.main.sync { ScreenInfo.current() }
        let visible = screen(containing: window.frame, in: screens).visible
        let spot = CGPoint(
            x: min(max((cursor.x - window.frame.minX) / window.frame.width, 0), 1),
            y: min(max((cursor.y - window.frame.minY) / window.frame.height, 0), 1)
        )
        let grip = ResizeGrip(spot: spot, size: window.frame.size)
        let anchor = Geometry.resizeAnchor(window.frame, in: visible, grip: grip)
        var s = ResizeSession(
            window: window, visible: visible, grip: grip, anchor: anchor,
            handSpread: handSpread.radial, target: window.frame
        )
        _ = s.smoother.filter(.zero, at: time)
        resize = s
        // Everything needed to tell afterward why a resize changed the wrong side, or nothing.
        let axes = Geometry.resizedAxes(grip)
        let changes = [axes.width ? "width" : nil, axes.height ? "height" : nil].compactMap { $0 }.joined(separator: " and ")
        let spans = Geometry.spans(window.frame, visible)
        let full = [spans.width ? "full width" : nil, spans.height ? "full height" : nil].compactMap { $0 }
        log(String(
            format: "resize began: %@ %@, pointer at (%.2f, %.2f) of it: %@, changes %@%@, anchor (%g, %g), hand spread %.3f",
            window.appName, describe(window.frame), spot.x, spot.y, grip.description, changes,
            full.isEmpty ? "" : " (already \(full.joined(separator: " and ")))", anchor.x, anchor.y, handSpread.radial
        ))

        let animator = self.animator
        DispatchQueue.main.async { animator.resize(window, anchor: anchor, cursorSpot: spot) }
    }

    private func updateResize(_ spread: Spread, at time: Double) {
        guard var s = resize else { return }
        let radial = s.smoother.filter(CGPoint(x: spread.radial, y: 0), at: time).x
        let scale = Geometry.resizeScale(
            grip: s.grip, start: s.handSpread, change: radial, exponent: resizeExponent
        )
        s.target = Geometry.resizedFrame(s.window.frame, scale: scale, anchor: s.anchor, within: s.visible, minimum: minimumSize)
        s.spread = spread
        s.updates += 1
        resize = s

        let target = s.target
        let animator = self.animator
        DispatchQueue.main.async { animator.setTarget(frame: target) }
    }

    private func endResize() {
        guard let s = resize else { return }
        resize = nil
        let animator = self.animator
        DispatchQueue.main.async { animator.release() }
        let spread = String(format: "x %+.3f y %+.3f radial %+.3f", s.spread.x, s.spread.y, s.spread.radial)
        log("resize ended: \(describe(s.target)) (\(s.updates) frames), spread \(spread)")
    }

    // MARK: Tap

    /// Maximizes the window under the pointer, or restores it if Tutamak maximized it.
    private func toggleMaximize() {
        let cursor = CGEvent(source: nil)?.location ?? .zero
        guard let window = grabWindow(at: cursor, needsSize: true) else { return }
        let screens = DispatchQueue.main.sync { ScreenInfo.current() }
        let visible = screen(containing: window.frame, in: screens).visible
        let key = window.element

        let target: CGRect
        let label: String
        var completion: ((CGRect) -> Void)?
        if let entry = restoreFrames[key], let after = entry.after, Geometry.isClose(window.frame, after) {
            target = entry.before
            label = "restored"
            restoreFrames[key] = nil
        } else if Geometry.isClose(window.frame, visible) {
            // It fills the screen, but not through Tutamak: nothing to restore, so bring it to a comfortable size.
            target = visible.insetBy(dx: (visible.width / 6).rounded(), dy: (visible.height / 6).rounded())
            label = "restored"
            restoreFrames[key] = nil
        } else {
            target = visible
            label = "maximized"
            remember(before: window.frame, for: key)
            completion = rememberActualFrame(of: key)
        }
        log("\(label): \(window.appName) \(describe(target))")

        let animator = self.animator
        DispatchQueue.main.async {
            animator.animate(window, from: window.frame, to: target, label: label, completion: completion)
        }
    }

    private func remember(before frame: CGRect, for key: AXUIElement) {
        if restoreFrames.count > 64 { restoreFrames.removeAll() }
        restoreFrames[key] = RestoreEntry(before: frame, after: nil)
    }

    /// Records the frame a maximized window actually took, reported from the AX queue.
    private func rememberActualFrame(of key: AXUIElement) -> (CGRect) -> Void {
        { [weak self] actual in
            self?.queue.async { self?.restoreFrames[key]?.after = actual }
        }
    }

    // MARK: Flick

    /// Posts the shortcut the flick stands for (see `SystemShortcut.init(flick:)`).
    private func flick(_ direction: SwipeDirection) {
        let shortcut = SystemShortcut(flick: direction)
        if shortcut.post() {
            log("flick \(direction): \(shortcut.title)")
        } else {
            log("flick \(direction): the \"\(shortcut.title)\" shortcut is turned off in Keyboard Shortcuts")
        }
    }

    // MARK: Helpers

    /// The window under the pointer, brought to the front; nil (and logged) if there is none to act on.
    private func grabWindow(at cursor: CGPoint, needsSize: Bool) -> TargetWindow? {
        guard AXIsProcessTrusted() else {
            log("no Accessibility permission; cannot touch windows")
            return nil
        }
        guard let window = AX.window(at: cursor) else {
            log("no movable window under the pointer")
            return nil
        }
        if needsSize, !AX.isSizeSettable(window.element) {
            log("\(window.appName) window cannot be resized")
            return nil
        }
        AX.raise(window)
        return window
    }

    private func screen(containing frame: CGRect, in screens: [ScreenInfo]) -> ScreenInfo {
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        return screens.first { $0.frame.contains(centre) }
            ?? screens.max { $0.frame.intersection(frame).area < $1.frame.intersection(frame).area }
            ?? ScreenInfo(frame: frame, visible: frame)
    }

    private func cancel() {
        tracker.reset()
        activeDevice = nil
        scrollBlocker.engaged = false
        endDrag()
        endResize()
        dropHold.reset()
        cancelDrop()
    }

    /// A zero-finger frame arrives when the fingers lift; if it does not, a drag or resize must not hang.
    private func scheduleWatchdog() {
        watchdog?.cancel()
        guard drag != nil || resize != nil else {
            watchdog = nil
            return
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.drag != nil || self.resize != nil else { return }
            self.log("no frames from the trackpad; gesture ended")
            self.cancel()
        }
        watchdog = item
        queue.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private func logDecision(_ d: GestureTracker.Decision) {
        let ms = Int((d.elapsed * 1000).rounded())
        let travel = String(format: "dx %+.3f dy %+.3f", d.travel.dx, d.travel.dy)
        let spread = String(format: "x %+.3f y %+.3f radial %+.3f", d.spread.x, d.spread.y, d.spread.radial)
        log("decision: \(d.kind.rawValue) (\(d.reason)) after \(ms) ms, travel \(travel), spread \(spread)")
    }

    private func describe(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height)))"
    }

    /// Notice level, so the system keeps the lines: `log show` can read back the last gestures
    /// after the fact (info lines live only in memory and are gone unless `log stream` was running).
    /// It is a few lines per gesture, never per frame unless `--debug` is on.
    private func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
